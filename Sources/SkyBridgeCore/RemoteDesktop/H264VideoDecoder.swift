import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// One H.264 implementation for camera and remote-desktop presentation. Parameter-set
/// staging and AVCC sample construction are shared; each stream owns its VT session.
/// Submission/teardown are serialized. The bounded count includes queued delivery work,
/// so a stalled consumer cannot retain an unbounded number of decoded IOSurfaces.
final class H264VideoDecoder: @unchecked Sendable {
  private let submissionQueue = DispatchQueue(label: "com.skybridge.compass.h264.submit")
  private let deliveryQueue = DispatchQueue(label: "com.skybridge.compass.h264.deliver")
  private let stateLock = NSLock()
  private var state = RemoteDecodeSubmissionState()
  private var active = true
  private var generation: UInt64 = 0
  private var session: VTDecompressionSession?
  private var formatDescription: CMVideoFormatDescription?
  private var parameterSets = H264ParameterSetTransitionState()
  private var previousSubmission: DispatchTime?
  private let maximumWidth: Int32
  private let maximumHeight: Int32
  private let frameHandler: @Sendable (DecodedFrameRingBuffer.BufferedFrame) -> Void
  private let failureHandler: @Sendable (RemoteFrameRenderError) -> Void
  private let syncFrameHandler: (@Sendable () -> Void)?
  private var needsSyncNotification = false

  init(
    maximumWidth: Int32 = 3_840,
    maximumHeight: Int32 = 2_160,
    frameHandler: @escaping @Sendable (DecodedFrameRingBuffer.BufferedFrame) -> Void,
    failureHandler: @escaping @Sendable (RemoteFrameRenderError) -> Void,
    syncFrameHandler: (@Sendable () -> Void)? = nil
  ) {
    self.maximumWidth = maximumWidth
    self.maximumHeight = maximumHeight
    self.frameHandler = frameHandler
    self.failureHandler = failureHandler
    self.syncFrameHandler = syncFrameHandler
  }

  deinit {
    if let session { VTDecompressionSessionInvalidate(session) }
  }

  func submit(data: Data) -> Result<RemoteH264FrameSubmissionResult, RemoteFrameRenderError> {
    submissionQueue.sync {
      Result { () throws(RemoteFrameRenderError) in try submitSerially(data: data) }
    }
  }

  /// Terminal boundary: callers create a new decoder for a new stream.
  func teardown() {
    submissionQueue.sync {
      stateLock.lock()
      active = false
      stateLock.unlock()
      retireSession()
      parameterSets.reset()
      formatDescription = nil
    }
  }

  private func submitSerially(data: Data) throws(RemoteFrameRenderError)
    -> RemoteH264FrameSubmissionResult
  {
    stateLock.lock()
    let isActive = active
    stateLock.unlock()
    guard isActive else { throw RemoteFrameRenderError.decoderClosed }
    let received = DispatchTime.now()
    let accessUnit: H264AnnexBAccessUnit
    do { accessUnit = try H264AnnexBAccessUnit.parse(data) } catch {
      throw RemoteFrameRenderError.invalidH264AccessUnit
    }
    parameterSets.stage(
      sequenceParameterSet: accessUnit.sequenceParameterSet,
      pictureParameterSet: accessUnit.pictureParameterSet)
    if let candidate = parameterSets.candidateForIDR(
      carriesSequenceParameterSet: accessUnit.sequenceParameterSet != nil,
      carriesPictureParameterSet: accessUnit.pictureParameterSet != nil,
      containsIDR: accessUnit.containsIDR
    ) {
      let description = try makeH264FormatDescription(
        sequenceParameterSet: candidate.sequenceParameterSet,
        pictureParameterSet: candidate.pictureParameterSet
      )
      // Drain the previous format before committing the new pair. A rejected
      // format never becomes active and old callbacks cannot cross the epoch.
      retireSession()
      session = try makeSession(formatDescription: description)
      formatDescription = description
      parameterSets.commit(candidate)
    }
    guard let formatDescription, let session else { return .awaitingParameterSets }
    guard parameterSets.pendingSequenceParameterSet == nil,
      parameterSets.pendingPictureParameterSet == nil
    else { return .awaitingSyncFrame }
    stateLock.lock()
    let waitingForSync = state.isWaitingForSyncFrame
    stateLock.unlock()
    guard !waitingForSync || accessUnit.containsIDR else { return .awaitingSyncFrame }
    let sampleData: Data
    do { sampleData = try accessUnit.makeAVCCSampleData() } catch H264AnnexBAccessUnitError
      .missingRenderableNALUnit
    {
      return waitingForSync ? .awaitingSyncFrame : .awaitingParameterSets
    } catch { throw RemoteFrameRenderError.invalidH264AccessUnit }
    let sample = try makeCompressedSampleBuffer(
      data: sampleData,
      formatDescription: formatDescription, isSyncFrame: accessUnit.containsIDR)
    stateLock.lock()
    guard state.begin(maximumInFlightCount: 3) else {
      state.markWaitingForSyncFrame()
      needsSyncNotification = true
      stateLock.unlock()
      return .droppedForBackpressure
    }
    if accessUnit.containsIDR {
      state.clearWaitingForSyncFrame()
      needsSyncNotification = false
    }
    let submittedGeneration = generation
    stateLock.unlock()
    let byteCount = data.count
    let status = VTDecompressionSessionDecodeFrame(
      session, sampleBuffer: sample, flags: ._EnableAsynchronousDecompression,
      infoFlagsOut: nil
    ) { [weak self] status, flags, imageBuffer, _, _ in
      let frame = imageBuffer.map {
        DecodedFrameRingBuffer.BufferedFrame(
          pixelBuffer: $0,
          recvTimestampNs: received.uptimeNanoseconds,
          decodeTimestampNs: DispatchTime.now().uptimeNanoseconds, recvBytes: byteCount)
      }
      self?.receive(
        frame: frame, status: status, dropped: flags.contains(.frameDropped),
        generation: submittedGeneration)
    }
    guard status == noErr else {
      complete(status: status, generation: submittedGeneration)
      throw RemoteFrameRenderError.videoToolboxDecodeFailed(status)
    }
    let delta =
      previousSubmission.map {
        max(Double(received.uptimeNanoseconds - $0.uptimeNanoseconds) / 1_000_000_000, 0.001)
      } ?? 0.016
    previousSubmission = received
    return .submitted(
      RenderMetrics(
        bandwidthMbps: Double(data.count) * 8 / (delta * 1_000_000),
        latencyMilliseconds: delta * 1_000))
  }

  private func receive(
    frame: DecodedFrameRingBuffer.BufferedFrame?, status: OSStatus,
    dropped: Bool, generation: UInt64
  ) {
    deliveryQueue.async { [weak self] in
      guard let self else { return }
      self.stateLock.lock()
      let isCurrent = self.active && generation == self.generation
      self.stateLock.unlock()
      guard isCurrent else { return }
      defer { self.complete(status: status, generation: generation) }
      if status != noErr {
        self.failureHandler(.videoToolboxDecodeFailed(status))
      } else if let frame {
        self.frameHandler(frame)
      } else if !dropped {
        self.failureHandler(.decodedFrameMissingImageBuffer)
      }
    }
  }

  private func complete(status: OSStatus, generation: UInt64) {
    stateLock.lock()
    var requestSync = false
    if generation == self.generation {
      state.complete(succeeded: status == noErr)
      // Wait for delivery capacity before asking the existing stream for an IDR.
      // A static desktop might otherwise never emit enough changes for its next GOP.
      if active, status == noErr, needsSyncNotification, state.inFlightCount == 0,
        state.isWaitingForSyncFrame
      {
        needsSyncNotification = false
        requestSync = true
      }
    }
    stateLock.unlock()
    if requestSync { syncFrameHandler?() }
  }

  private func retireSession() {
    stateLock.lock()
    generation &+= 1
    stateLock.unlock()
    if let session {
      VTDecompressionSessionWaitForAsynchronousFrames(session)
      VTDecompressionSessionInvalidate(session)
    }
    deliveryQueue.sync {}
    session = nil
    stateLock.lock()
    state.reset(waitingForSyncFrame: true)
    needsSyncNotification = false
    stateLock.unlock()
  }

  private func makeSession(formatDescription: CMVideoFormatDescription)
    throws(RemoteFrameRenderError) -> VTDecompressionSession
  {
    let attributes: [CFString: Any] = [
      kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
      kCVPixelBufferMetalCompatibilityKey: true,
      kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
    ]
    var created: VTDecompressionSession?
    let status = VTDecompressionSessionCreate(
      allocator: kCFAllocatorDefault,
      formatDescription: formatDescription, decoderSpecification: nil,
      imageBufferAttributes: attributes as CFDictionary, outputCallback: nil,
      decompressionSessionOut: &created)
    guard status == noErr, let created else {
      throw RemoteFrameRenderError.videoToolboxDecodeFailed(
        status == noErr ? kVTInvalidSessionErr : status)
    }
    let realtime = VTSessionSetProperty(
      created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    guard realtime == noErr else {
      VTDecompressionSessionInvalidate(created)
      throw RemoteFrameRenderError.videoToolboxDecodeFailed(realtime)
    }
    return created
  }

  private func makeH264FormatDescription(
    sequenceParameterSet: Data,
    pictureParameterSet: Data
  ) throws(RemoteFrameRenderError) -> CMVideoFormatDescription {
    var description: CMFormatDescription?
    let status = sequenceParameterSet.withUnsafeBytes { sequenceRaw -> OSStatus in
      guard let sequenceBase = sequenceRaw.baseAddress else {
        return kCMFormatDescriptionError_InvalidParameter
      }
      return pictureParameterSet.withUnsafeBytes { pictureRaw -> OSStatus in
        guard let pictureBase = pictureRaw.baseAddress else {
          return kCMFormatDescriptionError_InvalidParameter
        }
        let pointers: [UnsafePointer<UInt8>] = [
          sequenceBase.assumingMemoryBound(to: UInt8.self),
          pictureBase.assumingMemoryBound(to: UInt8.self),
        ]
        let sizes = [sequenceParameterSet.count, pictureParameterSet.count]
        return pointers.withUnsafeBufferPointer { pointerBuffer in
          sizes.withUnsafeBufferPointer { sizeBuffer in
            guard let pointerBase = pointerBuffer.baseAddress,
              let sizeBase = sizeBuffer.baseAddress
            else {
              return kCMFormatDescriptionError_InvalidParameter
            }
            return CMVideoFormatDescriptionCreateFromH264ParameterSets(
              allocator: kCFAllocatorDefault,
              parameterSetCount: pointerBuffer.count,
              parameterSetPointers: pointerBase,
              parameterSetSizes: sizeBase,
              nalUnitHeaderLength: 4,
              formatDescriptionOut: &description
            )
          }
        }
      }
    }
    guard status == noErr, let description else {
      throw RemoteFrameRenderError.invalidH264FormatDescription(status)
    }
    let dimensions = CMVideoFormatDescriptionGetDimensions(description)
    guard dimensions.width > 0,
      dimensions.height > 0,
      dimensions.width <= maximumWidth,
      dimensions.height <= maximumHeight
    else {
      throw RemoteFrameRenderError.unsupportedH264Dimensions(
        width: dimensions.width,
        height: dimensions.height
      )
    }
    return description
  }

  private func makeCompressedSampleBuffer(
    data: Data,
    formatDescription: CMVideoFormatDescription,
    isSyncFrame: Bool
  ) throws(RemoteFrameRenderError) -> CMSampleBuffer {
    var blockBuffer: CMBlockBuffer?
    var status = CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault,
      memoryBlock: nil,
      blockLength: data.count,
      blockAllocator: kCFAllocatorDefault,
      customBlockSource: nil,
      offsetToData: 0,
      dataLength: data.count,
      flags: 0,
      blockBufferOut: &blockBuffer
    )
    guard status == kCMBlockBufferNoErr, let blockBuffer else {
      throw RemoteFrameRenderError.compressedSampleBufferCreationFailed(status)
    }
    status = data.withUnsafeBytes { rawBuffer in
      guard let baseAddress = rawBuffer.baseAddress else {
        return kCMFormatDescriptionError_InvalidParameter
      }
      return CMBlockBufferReplaceDataBytes(
        with: baseAddress,
        blockBuffer: blockBuffer,
        offsetIntoDestination: 0,
        dataLength: data.count
      )
    }
    guard status == kCMBlockBufferNoErr else {
      throw RemoteFrameRenderError.compressedSampleBufferCreationFailed(status)
    }

    var sampleBuffer: CMSampleBuffer?
    var sampleSize = data.count
    status = CMSampleBufferCreate(
      allocator: kCFAllocatorDefault,
      dataBuffer: blockBuffer,
      dataReady: true,
      makeDataReadyCallback: nil,
      refcon: nil,
      formatDescription: formatDescription,
      sampleCount: 1,
      sampleTimingEntryCount: 0,
      sampleTimingArray: nil,
      sampleSizeEntryCount: 1,
      sampleSizeArray: &sampleSize,
      sampleBufferOut: &sampleBuffer
    )
    guard status == noErr, let sampleBuffer else {
      throw RemoteFrameRenderError.compressedSampleBufferCreationFailed(status)
    }
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(
      sampleBuffer,
      createIfNecessary: true
    ), CFArrayGetCount(attachments) > 0 {
      let dictionary = unsafeBitCast(
        CFArrayGetValueAtIndex(attachments, 0),
        to: CFMutableDictionary.self
      )
      CFDictionarySetValue(
        dictionary,
        Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
        Unmanaged.passUnretained(isSyncFrame ? kCFBooleanFalse : kCFBooleanTrue).toOpaque()
      )
    }
    return sampleBuffer
  }

}

#!/usr/bin/env python3
"""Compile exact iOS retry methods with isolated dependencies, never an app/keychain.

The source boundary is deliberate: task sleep records delays and yields; fake
connect injects EOF/current failure or a verified receipt. Crypto/network/UI are
not reproduced. Full cleanup, scheduler, lease store, receipt validation and
budget helper are compiled from the requested source. Source call-site checks
ensure the three production connect success branches actually use that helper.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

parser=argparse.ArgumentParser()
parser.add_argument('--source',type=Path,default=Path(__file__).resolve().parents[1]/'SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift')
parser.add_argument('--output',type=Path,required=True)
args=parser.parse_args()
s=args.source.read_text(); args.output.mkdir(parents=True,exist_ok=True)
def block(marker):
 start=s.index(marker); begin=s.index('{',start); depth=1; end=begin+1
 while depth:
  if s[end]=='{':depth+=1
  elif s[end]=='}':depth-=1
  end+=1
 return s[start:end]
def method(name):return block('    private func '+name+'(')
names=['scheduleReconnectIfNeeded','finishReconnectTask','cancelReconnectTask','cleanupBrokenInboundConnection','removeTrackedConnectionIfOwned','cancelPeerProtectionRoots','isCurrentAuthenticatedConnection','requireCurrentAuthenticatedConnection']
methods=[method(n) for n in names]
new='    private func completeReconnectAfterAuthentication(' in s
if new:methods.append(method('completeReconnectAfterAuthentication'))
else:
 # Historical connect's final synchronous commit validated the same receipt,
 # but performed no reset. The wrapper only exposes that statement to tests.
 methods.append('private func completeReconnectAfterAuthentication(_ establishedReceipt:AuthenticatedConnectionReceipt) throws {try requireCurrentAuthenticatedConnection(establishedReceipt)}')
lease=block('struct P2PConnectionLease<')+'\n'+block('struct P2PConnectionLeaseStore<')
start=s.index('            let hadRuntimeConnection = connections[runtimePeerId] != nil',s.index('public func disconnect('))
end=s.index('            if hadRuntimeConnection {',start)
disconnect_prefix=s[start:end]

pre=r"""
import Foundation
final class NWConnection: @unchecked Sendable { func cancel() {} }
typealias Lease = P2PConnectionLease<NWConnection>
struct AuthenticatedConnectionReceipt {let lease:Lease;let sessionId:String;let negotiatedSuite:Int}
struct Current {let receipt:AuthenticatedConnectionReceipt;let peerId:String}
struct SessionKeys {let sessionId:String;let negotiatedSuite:Int}
enum P2PError:Error {case staleConnectionIncarnation}
struct Device {}
struct Pending {let peerId:String}
struct AudioAdmission {let generation:UUID}
enum Status {case failed,connecting}
enum Stage {case cleanupBegin,cleanupNotOwned,cleanupRetired}
actor Driver {func cancel() async {}}
actor Transport {func removeConnection(_ c:NWConnection,for p:String,leaseSequence:UInt64) async->Bool {true}}
final class Discovery {func setConnectionLiveness(for d:Device,isConnected:Bool){}}
final class SkyBridgeLogger:Sendable {static let shared=SkyBridgeLogger();func info(_ text:String){}}
@MainActor final class SettingsManager { static let instance=SettingsManager(); var autoReconnect=true }
@MainActor enum TestClock {
 static var delays:[Double]=[]
 static func sleep(seconds:Double) async throws {delays.append(seconds);await Task.yield();try Task.checkCancellation()}
}
@MainActor final class Fixture {
 var reconnectAttempts:[String:Int]=[:]
 var reconnectTasks:[String:Task<Void,Never>]=[:]
 var reconnectTaskTokens:[String:UUID]=[:]
 var userInitiatedDisconnects=Set<String>(),reconnectSuppressedDeviceIds=Set<String>()
 var lastKnownDevices:[String:Device]=["peer":Device()]
 var connectionErrorByDeviceId:[String:String]=[:]
 var bootstrapRekeyTasks:[String:Task<Void,Never>]=[:],heartbeatTasks:[String:Task<Void,Never>]=[:],pathRecoveryTasks:[String:Task<Void,Never>]=[:]
 var pendingPairingTrustRequest:Pending?
 let maxReconnectAttempts=8
 var connections=P2PConnectionLeaseStore<NWConnection>()
 var audioAdmissionByRuntimePeerId:[String:AudioAdmission]=[:]
 func invalidateAudio(for peer:String,generation:UUID,forgetPeer:Bool,forgetHistory:Bool){}
 var sharedSecrets:[String:Int]=[:],inboundRekeyRollbackByPeerId:[String:Int]=[:],negotiatedSuiteByDeviceId:[String:Int]=[:],heartbeatOperationByPeerId:[String:Int]=[:]
 var peerPresentationIdByRuntimePeerId:[String:String]=[:],connectionStatusByDeviceId:[String:Status]=[:]
 var rekeyStatusByDeviceId:[String:Int]=[:],rekeyInProgress=Set<String>()
 let discoveryManager=Discovery();let transport:Transport?=Transport()
 static let protocolIdentityLogRedaction="redacted"
 static func smokeSanitize(_ s:String)->String{s}
 func traceSessionRuntime(_ stage:Stage,peerId:String,connection:NWConnection){}
 func canonicalPeerLookupKey(_ s:String)->String{s}
 func smokeInboundTrace(_ s:String){}
 func finishProvisionalInboundConnection(_ c:NWConnection){}
 func connectionStatePeerIds(for p:String)->[String]{[p]}
 func presentationPeerId(for p:String)->String{p}
 func currentAuthenticatedSession(forAnyPeerId p:String,requireConnectedStatus:Bool)->Current?{nil}
 func exactAuthenticatedSession(for p:String,requireConnectedStatus:Bool)->Current? {
  guard let lease=connections.lease(for:p),let keys=sessionKeys[p],sessionKeyConnectionGenerationByPeerId[p]==lease.generation else{return nil}
  return Current(receipt:AuthenticatedConnectionReceipt(lease:lease,sessionId:keys.sessionId,negotiatedSuite:keys.negotiatedSuite),peerId:p)
 }
 func invalidatePendingPairingIdentityRequests(for p:String,connectionGeneration:UUID){}
 func detachHandshakeOperationIfOwned(for p:String,connectionGeneration:UUID)->Driver?{nil}
 func removeSessionKeysIfOwned(for p:String,connectionGeneration:UUID){}
 func clearSessionPairingAuthority(for p:String,connectionGeneration:UUID){}
 func syncPresentationState(for p:String){}
 func makeActiveConnectionDevice(peerId:String,connection:NWConnection)->Device{Device()}
 func purgeTerminalConnectionPresentationState(for p:String){}
 func detachArbiterSessionBinding(for p:String,expectedConnectionGeneration:UUID)->Int?{nil}
 func releaseArbiterSessionBinding(_ binding:Int) async{}
 func connectionAliasSet(for p:String)->Set<String>{p == "peer" ? ["peer","alias"] : [p]}
 func stateKeysMatchingAliases<S:Sequence>(_ aliases:Set<String>,keys:S)->[String] where S.Element==String { keys.filter{aliases.contains($0)} }
 func cancelPathRecoveryTask(deviceId:String){pathRecoveryTasks.removeValue(forKey:deviceId)?.cancel()}
 func userVisibleConnectionError(_ e:Error)->String{"fixture transport failure"}

 var sessionKeys:[String:SessionKeys]=[:]
 var sessionKeyConnectionGenerationByPeerId:[String:UUID]=[:]
 enum Failure:Error {case connection}
 enum Mode {case cleanup,roots,success,lateSuccess}
 var mode=Mode.cleanup
 var calls=0
 var seenBudgets:[Int]=[]
 func installAuthenticated() throws->AuthenticatedConnectionReceipt {
  let lease=try connections.install(NWConnection(),for:"peer")
  let session=UUID().uuidString
  sessionKeys["peer"]=SessionKeys(sessionId:session,negotiatedSuite:18)
  sessionKeyConnectionGenerationByPeerId["peer"]=lease.generation
  return AuthenticatedConnectionReceipt(lease:lease,sessionId:session,negotiatedSuite:18)
 }
 func connect(to device:Device) async throws {
  calls+=1;seenBudgets.append(reconnectAttempts["peer"] ?? 0)
  if mode == .success || mode == .lateSuccess {
   let receipt=try installAuthenticated()
   try completeReconnectAfterAuthentication(receipt)
   if mode == .lateSuccess {
    _=try installAuthenticated()
    reconnectAttempts["peer"]=6 // Replacement episode published before old caller resumes.
    await Task.yield()
   }
   return
  }
  let c=NWConnection();let lease=try connections.install(c,for:"peer")
  if mode == .cleanup {await cleanupBrokenInboundConnection(c,peerId:"peer",reason:"fixture EOF")}
  else {cancelFailureRoots();_ = connections.removeIfOwned(lease,for:"peer")}
  if calls>=12 {reconnectSuppressedDeviceIds.insert("peer")} // Finite harness guard only.
  throw Failure.connection
 }
 func run(_ mode:Mode) async->(Int,[Double],[Int]) {
  self.mode=mode;TestClock.delays=[];scheduleReconnectIfNeeded(deviceId:"peer")
  for _ in 0..<2000 {await Task.yield()}
  return(calls,TestClock.delays,seenBudgets)
 }
 func staleOwnerKeepsBudget() async throws->Bool {
  reconnectAttempts["peer"]=7
  let old=NWConnection(),replacement=NWConnection()
  _ = try connections.install(replacement,for:"peer")
  await cleanupBrokenInboundConnection(old,peerId:"peer",reason:"old EOF")
  return reconnectAttempts["peer"]==7 && connections["peer"] === replacement
 }
 func explicitStop() async->Bool {
  scheduleReconnectIfNeeded(deviceId:"peer")
  let runtimePeerId="peer"
  var didDisconnect=false
  __DISCONNECT_PREFIX__
  _ = hadRuntimeConnection
  for _ in 0..<20 {await Task.yield()}
  return didDisconnect && calls==0 && reconnectAttempts["peer"]==nil && reconnectTasks.isEmpty
 }
 func manualSuccess() throws->Bool {
  let receipt=try installAuthenticated()
  reconnectAttempts=["peer":7,"alias":5,"other":4]
  try completeReconnectAfterAuthentication(receipt)
  return reconnectAttempts == ["other":4]
 }
 func staleSuccess() throws->Bool {
  let old=try installAuthenticated()
  _=try installAuthenticated();reconnectAttempts["peer"]=6
  do {try completeReconnectAfterAuthentication(old);return false}
  catch {return reconnectAttempts["peer"]==6}
 }
 func missingKeysDoesNotReset() throws->Bool {
  let receipt=try installAuthenticated()
  sessionKeys.removeValue(forKey:"peer");reconnectAttempts["peer"]=7
  do {try completeReconnectAfterAuthentication(receipt);return false}
  catch {return reconnectAttempts["peer"]==7}
 }
 func changedSessionDoesNotReset() throws->Bool {
  let receipt=try installAuthenticated()
  sessionKeys["peer"]=SessionKeys(sessionId:"replacement",negotiatedSuite:18)
  reconnectAttempts["peer"]=7
  do {try completeReconnectAfterAuthentication(receipt);return false}
  catch {return reconnectAttempts["peer"]==7}
 }
 func cancelledSuccess() async throws->Bool {
  let receipt=try installAuthenticated();reconnectAttempts["peer"]=7
  let task=Task { @MainActor in
   withUnsafeCurrentTask {$0?.cancel()}
   do {try self.completeReconnectAfterAuthentication(receipt);return false}
   catch {return self.reconnectAttempts["peer"]==7}
  }
  return await task.value
 }
 func staleTaskToken() async->Bool {
  scheduleReconnectIfNeeded(deviceId:"peer")
  reconnectTaskTokens["peer"]=UUID()
  for _ in 0..<20 {await Task.yield()}
  let ok=calls==0 && reconnectAttempts["peer"]==1
  cancelReconnectTask(deviceId:"peer")
  return ok
 }
 func autoReconnectDisabled() async->Bool {
  SettingsManager.instance.autoReconnect=false
  defer {SettingsManager.instance.autoReconnect=true}
  scheduleReconnectIfNeeded(deviceId:"peer")
  for _ in 0..<20 {await Task.yield()}
  return calls==0 && reconnectTasks.isEmpty && reconnectAttempts["peer"]==nil
 }
 func autoReconnectDisabledWhilePending() async->Bool {
  scheduleReconnectIfNeeded(deviceId:"peer")
  SettingsManager.instance.autoReconnect=false
  defer {SettingsManager.instance.autoReconnect=true}
  for _ in 0..<20 {await Task.yield()}
  return calls==0 && reconnectTasks.isEmpty && reconnectAttempts["peer"]==1
 }
 func explicitRootReset()->Bool {
  reconnectAttempts=["peer":7,"alias":5,"other":4]
  cancelIntentionalRoots()
  return reconnectAttempts == ["other":4]
 }
 func failedRootPreservesAliases()->Bool {
  reconnectAttempts=["peer":7,"alias":5,"other":4]
  cancelFailureRoots()
  return reconnectAttempts == ["peer":7,"alias":5,"other":4]
 }
"""
post=r"""
}
@main struct Main {
 @MainActor static func main() async throws {
  var cases:[(String,Bool)]=[]
  let cleanup=Fixture(),roots=Fixture(),auto=Fixture(),late=Fixture(),stale=Fixture(),stop=Fixture()
  let a=await cleanup.run(.cleanup), b=await roots.run(.roots)
  let expected:[Double]=[1,2,4,8,16,30,30,30]
  cases.append(("preauth_eof_bounded",a.0==8 && a.1==expected && a.2==Array(1...8)))
  cases.append(("socket_failure_bounded",b.0==8 && b.1==expected && b.2==Array(1...8)))
  _=await auto.run(.success);cases.append(("automatic_authenticated_success",auto.reconnectAttempts.isEmpty))
  _=await late.run(.lateSuccess);cases.append(("old_success_return_cannot_clear_replacement",late.reconnectAttempts["peer"]==6))
  cases.append(("stale_cleanup_preserves_replacement",try await stale.staleOwnerKeepsBudget()))
  cases.append(("explicit_disconnect_during_backoff",await stop.explicitStop()))
  cases.append(("manual_authenticated_success_and_aliases",try Fixture().manualSuccess()))
  cases.append(("stale_auth_receipt_cannot_reset",try Fixture().staleSuccess()))
  cases.append(("missing_session_keys_cannot_reset",try Fixture().missingKeysDoesNotReset()))
  cases.append(("wrong_session_id_cannot_reset",try Fixture().changedSessionDoesNotReset()))
  let cancelled=Fixture(),staleTask=Fixture()
  cases.append(("cancelled_commit_cannot_reset",try await cancelled.cancelledSuccess()))
  cases.append(("stale_scheduled_token_cannot_connect",await staleTask.staleTaskToken()))
  cases.append(("explicit_peer_stop_resets_aliases",Fixture().explicitRootReset()))
  cases.append(("failure_cleanup_preserves_aliases",Fixture().failedRootPreservesAliases()))
  let disabled=Fixture(),disabledPending=Fixture()
  cases.append(("auto_reconnect_disabled_before_queue",await disabled.autoReconnectDisabled()))
  cases.append(("auto_reconnect_disabled_during_backoff",await disabledPending.autoReconnectDisabledWhilePending()))
  withExtendedLifetime((cleanup,roots,auto,late,stale,stop,cancelled,staleTask,disabled,disabledPending)){}
  for (name,passed) in cases {print("CASE|\(name)|\(passed ? "PASS" : "FAIL")")}
  print("eof_attempts=\(a.0) delays=\(a.1) budgets=\(a.2)")
  print("socket_attempts=\(b.0) delays=\(b.1) budgets=\(b.2)")
  if cases.contains(where:{!$0.1}) {exit(1)}
 }
}
"""

pre=pre.replace('__DISCONNECT_PREFIX__',disconnect_prefix)
if 'didDisconnect = true' not in disconnect_prefix:pre=pre.replace('var didDisconnect=false','let didDisconnect=false')
pre+=' func cancelFailureRoots(){cancelPeerProtectionRoots(for:"peer"'+(',resetReconnectBudget:false' if new else '')+')}\n'
pre+=' func cancelIntentionalRoots(){cancelPeerProtectionRoots(for:"peer"'+(',resetReconnectBudget:true' if new else '')+')}\n'
code='import Foundation\n'+lease+'\n'+pre+'\n'.join(methods)+post
code=code.replace('try await Task.sleep(for: .seconds(delay))','try await TestClock.sleep(seconds: delay)')
file=args.output/'ExtractedReconnect.swift'; file.write_text(code)
command=['swiftc','-swift-version','6','-warnings-as-errors','-D','SKYBRIDGE_TESTING','-parse-as-library',str(file),'-o',str(args.output/'reconnect-regression')]
compiled=subprocess.run(command,capture_output=True,text=True)
(args.output/'compile.log').write_text(compiled.stdout+compiled.stderr)
result={'source':str(args.source),'sourceSHA256':hashlib.sha256(args.source.read_bytes()).hexdigest(),'compileCommand':command,'compileExit':compiled.returncode,'extractedMethods':names+(['completeReconnectAfterAuthentication'] if new else [])}
if compiled.returncode:
 print(compiled.stdout+compiled.stderr);(args.output/'results.json').write_text(json.dumps(result,indent=2));sys.exit(2)
run=subprocess.run([str(args.output/'reconnect-regression')],capture_output=True,text=True)
(args.output/'run.log').write_text(run.stdout+run.stderr)
checks={}
connect=block('    private func connect(to device: DiscoveredDevice, selectedTarget: IOSSelectedConnectionTarget?)')
public_connect=block('    public func connect(to device: DiscoveredDevice)')
checks['public_connect_delegates_selected_target']='try await connect(to: directLAN?.device ?? device, selectedTarget:' in public_connect
checks['three_connect_success_commits']=connect.count('try completeReconnectAfterAuthentication(')==3
checks['no_async_success_reset']= 'self.reconnectAttempts.removeValue' not in method('scheduleReconnectIfNeeded')
checks['failed_cancelled_preserve_budget']=s.count('cancelPeerProtectionRoots(for: runtimePeerId, resetReconnectBudget: false)')==2
checks['intentional_disconnects_reset_budget']=s.count('cancelPeerProtectionRoots(for: runtimePeerId, resetReconnectBudget: true)')==2
checks['forget_retains_reset']='reconnectAttempts.removeValue(forKey: key)' in block('    public func clearTrustMaterialForForgottenDevice(')
checks['max_eight_unchanged']='private let maxReconnectAttempts: Int = 8' in s
result.update(runExit=run.returncode,caseResults=[dict(zip(['case','status'],line.split('|')[1:])) for line in run.stdout.splitlines() if line.startswith('CASE|')],sourceWiringChecks=checks)
(args.output/'results.json').write_text(json.dumps(result,indent=2))
print(run.stdout);print(json.dumps(checks,indent=2))
sys.exit(0 if run.returncode==0 and all(checks.values()) else 1)

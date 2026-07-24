import SkyBridgeQPeriaptRuntime

// Source-compatible policy/runtime names retained for SkyBridgeCore clients.
// All verification, CAS orchestration, and session construction live in the
// shared runtime so Apple platform targets cannot drift independently.
public typealias QPeriaptSignedPolicyMaterial =
    SkyBridgeQPeriaptRuntime.QPeriaptSignedPolicyMaterial
public typealias QPeriaptEnrollmentMode =
    SkyBridgeQPeriaptRuntime.QPeriaptEnrollmentMode
public typealias QPeriaptTrustedStateStore =
    SkyBridgeQPeriaptRuntime.QPeriaptTrustedStateStore
public typealias QPeriaptPolicyRuntimeError =
    SkyBridgeQPeriaptRuntime.QPeriaptPolicyRuntimeError
public typealias QPeriaptRuntimeSession =
    SkyBridgeQPeriaptRuntime.QPeriaptRuntimeSession
public typealias QPeriaptPolicyRuntime =
    SkyBridgeQPeriaptRuntime.QPeriaptPolicyRuntime

using System.Runtime.InteropServices;

namespace Skybridge.WinClient.Services;

public sealed partial class CoreBridge
{
    // This synchronous boundary borrows the actual arrays only until native returns.
    // Lengths are derived here; managed callers cannot supply pointers or capacities.
    internal static int QPeriaptResolvePolicy(byte[] policy, byte[] signature, byte[] key,
        byte[] previousState, byte[] decision) => NativeMethods.QPeriaptResolvePolicy(
            policy, (nuint)policy.Length, signature, (nuint)signature.Length,
            key, (nuint)key.Length, previousState, (nuint)previousState.Length,
            decision, (nuint)decision.Length);

    internal static int QPeriaptGenerateKeyPair(byte[] decision, byte[] privatePq, byte[] publicPq,
        byte[] privateTraditional, byte[] publicTraditional) => NativeMethods.QPeriaptGenerateKeyPair(
            decision, (nuint)decision.Length, privatePq, (nuint)privatePq.Length,
            publicPq, (nuint)publicPq.Length, privateTraditional, (nuint)privateTraditional.Length,
            publicTraditional, (nuint)publicTraditional.Length);

    internal static int QPeriaptEncapsulate(byte[] decision, byte[] publicPq, byte[] publicTraditional,
        byte[] context, byte[] ciphertextPq, byte[] ciphertextTraditional, byte[] secret) =>
        NativeMethods.QPeriaptEncapsulate(decision, (nuint)decision.Length,
            publicPq, (nuint)publicPq.Length, publicTraditional, (nuint)publicTraditional.Length,
            context, (nuint)context.Length, ciphertextPq, (nuint)ciphertextPq.Length,
            ciphertextTraditional, (nuint)ciphertextTraditional.Length, secret, (nuint)secret.Length);

    internal static int QPeriaptDecapsulate(byte[] decision, byte[] privatePq, byte[] ciphertextPq,
        byte[] publicPq, byte[] privateTraditional, byte[] ciphertextTraditional, byte[] publicTraditional,
        byte[] context, byte[] secret) => NativeMethods.QPeriaptDecapsulate(
            decision, (nuint)decision.Length, privatePq, (nuint)privatePq.Length,
            ciphertextPq, (nuint)ciphertextPq.Length, publicPq, (nuint)publicPq.Length,
            privateTraditional, (nuint)privateTraditional.Length,
            ciphertextTraditional, (nuint)ciphertextTraditional.Length,
            publicTraditional, (nuint)publicTraditional.Length,
            context, (nuint)context.Length, secret, (nuint)secret.Length);

    private static partial class NativeMethods
    {
        [DllImport("skybridge_core", EntryPoint = "skybridge_q_periapt_decision_from_signed_policy", CallingConvention = CallingConvention.Cdecl)]
        internal static extern int QPeriaptResolvePolicy(
            [In] byte[] policy, nuint policyLength,
            [In] byte[] signature, nuint signatureLength,
            [In] byte[] verificationKey, nuint verificationKeyLength,
            [In] byte[] previousTrustedState, nuint previousTrustedStateLength,
            [Out] byte[] decision, nuint decisionLength);

        [DllImport("skybridge_core", EntryPoint = "skybridge_q_periapt_generate_keypair", CallingConvention = CallingConvention.Cdecl)]
        internal static extern int QPeriaptGenerateKeyPair(
            [In] byte[] decision, nuint decisionLength,
            [Out] byte[] privatePq, nuint privatePqLength,
            [Out] byte[] publicPq, nuint publicPqLength,
            [Out] byte[] privateTraditional, nuint privateTraditionalLength,
            [Out] byte[] publicTraditional, nuint publicTraditionalLength);

        [DllImport("skybridge_core", EntryPoint = "skybridge_q_periapt_encapsulate", CallingConvention = CallingConvention.Cdecl)]
        internal static extern int QPeriaptEncapsulate(
            [In] byte[] decision, nuint decisionLength,
            [In] byte[] publicPq, nuint publicPqLength,
            [In] byte[] publicTraditional, nuint publicTraditionalLength,
            [In] byte[] applicationContext, nuint applicationContextLength,
            [Out] byte[] ciphertextPq, nuint ciphertextPqLength,
            [Out] byte[] ciphertextTraditional, nuint ciphertextTraditionalLength,
            [Out] byte[] secret, nuint secretLength);

        [DllImport("skybridge_core", EntryPoint = "skybridge_q_periapt_decapsulate", CallingConvention = CallingConvention.Cdecl)]
        internal static extern int QPeriaptDecapsulate(
            [In] byte[] decision, nuint decisionLength,
            [In] byte[] privatePq, nuint privatePqLength,
            [In] byte[] ciphertextPq, nuint ciphertextPqLength,
            [In] byte[] publicPq, nuint publicPqLength,
            [In] byte[] privateTraditional, nuint privateTraditionalLength,
            [In] byte[] ciphertextTraditional, nuint ciphertextTraditionalLength,
            [In] byte[] publicTraditional, nuint publicTraditionalLength,
            [In] byte[] applicationContext, nuint applicationContextLength,
            [Out] byte[] secret, nuint secretLength);
    }
}

using System.Security.Cryptography;

namespace Skybridge.WinClient.Services.RemoteControl;

public sealed partial class RemoteControlIdentityStore
{
    internal const string Schema1BackupName = "remote-control-identity.schema1.bin";
    private QPeriaptRuntimeSession? _qSession;
    private QPeriaptKeyPair? _qKey;
    internal QPeriaptEnrollmentMode PolicyEnrollmentMode => RequirePolicySession().EnrollmentMode;

    private QPeriaptRuntimeSession RequirePolicySession() => _qSession
        ?? throw new InvalidOperationException("The identity has no admitted Q-Periapt policy session.");
    private QPeriaptKeyPair RequirePolicyKey() => _qKey
        ?? throw new InvalidOperationException("The identity has no policy-bound KEM key.");

    private static void ValidateDocumentSchema(IdentityDocument document)
    {
        if (document.SigningPrivateKey is null || document.KemDecapsulationKey is null || document.TrustedMaterials is null ||
            document.SchemaVersion is not (1 or 2) ||
            (document.SchemaVersion == 1 && (document.QPeriaptEnrolled || document.QPeriaptPrivateKey is not null)) ||
            (document.SchemaVersion == 2 && (!document.QPeriaptEnrolled || document.QPeriaptPrivateKey?.Length != QPeriaptKeyEncoding.PrivateLength)))
        { throw new InvalidDataException("Stored remote-control identity schema is invalid."); }
    }

    private void PreparePolicyBoundIdentity(IdentityDocument document, bool created, byte[] protectedPreimage,
        CancellationToken cancellationToken)
    {
        var policyStore = new QPeriaptTrustedStateStore(_directory, _protector, _committer);
        _qSession = QPeriaptRuntimeSession.Prepare(policyStore, document.SchemaVersion == 2, cancellationToken);
        if (document.SchemaVersion == 2)
        {
            var expanded = document.QPeriaptPrivateKey ?? throw new InvalidDataException("The enrolled identity has no expanded Q key.");
            _qKey = QPeriaptKeyEncoding.Import(_qSession, expanded);
        }
        else { _qKey = QPeriaptNativeClient.GenerateKeyPair(_qSession.Decision, cancellationToken); }
        PublicMaterial = RemoteControlPairingMaterial.CreatePolicyBound(PublicMaterial.DeviceId, PublicMaterial.DeviceName,
            PublicMaterial.ProtocolPublicKey.Span, PublicMaterial.MlKem768PublicKey.Span, QPeriaptKeyEncoding.ExportPublic(_qKey));
        if (document.SchemaVersion == 1)
        {
            if (!created) { PreserveSchema1Preimage(protectedPreimage); }
            Persist(_trusted, cancellationToken);
        }
    }

    private void PreserveSchema1Preimage(byte[] protectedPreimage)
    {
        if (protectedPreimage.Length is <= 0 or > MaximumStoredBytes)
        { throw new InvalidDataException("The identity migration has no bounded schema 1 preimage."); }
        var anchorPath = Path.Combine(_directory, Schema1BackupName);
        RejectLinkIfPresent(anchorPath);
        IdentityDocument? anchor = null;
        byte[] anchorBytes = [];
        try
        {
            try { anchor = ReadDocument(anchorPath, _protector, out anchorBytes); }
            catch (FileNotFoundException)
            {
                CommitImmutableSchema1Preimage(anchorPath, protectedPreimage);
                return;
            }
            if (anchorBytes.AsSpan().SequenceEqual(protectedPreimage))
            {
                MarkPreimageReadOnly(anchorPath);
                return;
            }
            ValidateDocumentSchema(anchor);
            if (anchor.SchemaVersion != 1)
            { throw new InvalidDataException("The original migration preimage must use schema 1."); }
            var anchorIdentity = ValidateLocalIdentity(anchor.DeviceId, anchor.DeviceName,
                anchor.SigningPrivateKey, anchor.KemDecapsulationKey);
            _ = ReadTrustedMaterials(anchor, anchorIdentity);
            if (anchorIdentity.DeviceId != PublicMaterial.DeviceId ||
                !anchorIdentity.ProtocolPublicKey.Span.SequenceEqual(PublicMaterial.ProtocolPublicKey.Span) ||
                !anchorIdentity.MlKem768PublicKey.Span.SequenceEqual(PublicMaterial.MlKem768PublicKey.Span))
            { throw new InvalidDataException("The original migration preimage belongs to a different device or cryptographic identity."); }
            // Ciphertext hashing identifies this exact snapshot for idempotent retry.
            // It is not an authenticity check; both identities were independently validated above.
            var name = $"remote-control-identity.schema1.{Convert.ToHexStringLower(SHA256.HashData(protectedPreimage))}.bin";
            CommitImmutableSchema1Preimage(Path.Combine(_directory, name), protectedPreimage);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(anchorBytes);
            if (anchor?.SigningPrivateKey is not null) { CryptographicOperations.ZeroMemory(anchor.SigningPrivateKey); }
            if (anchor?.KemDecapsulationKey is not null) { CryptographicOperations.ZeroMemory(anchor.KemDecapsulationKey); }
            if (anchor?.QPeriaptPrivateKey is not null) { CryptographicOperations.ZeroMemory(anchor.QPeriaptPrivateKey); }
        }
    }

    private bool MatchesExistingSchema1Preimage(string backupPath, byte[] protectedPreimage)
    {
        RejectLinkIfPresent(backupPath);
        FileStream existing;
        try { existing = new FileStream(backupPath, FileMode.Open, FileAccess.Read, FileShare.Read); }
        catch (FileNotFoundException) { return false; }
        using (existing)
        {
            if (existing.Length != protectedPreimage.Length)
            { throw new IOException("The schema 1 snapshot target contains different bytes."); }
            var bytes = new byte[protectedPreimage.Length];
            try
            {
                existing.ReadExactly(bytes);
                if (!bytes.AsSpan().SequenceEqual(protectedPreimage))
                { throw new IOException("The schema 1 snapshot target conflicts with its exact preimage."); }
            }
            finally { CryptographicOperations.ZeroMemory(bytes); }
            MarkPreimageReadOnly(backupPath);
            return true;
        }
    }

    private void CommitImmutableSchema1Preimage(string backupPath, byte[] protectedPreimage)
    {
        if (MatchesExistingSchema1Preimage(backupPath, protectedPreimage)) { return; }
        var temporary = Path.Combine(_directory, $".identity-schema1-preimage.{Guid.NewGuid():N}.tmp");
        try
        {
            using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough))
            { output.Write(protectedPreimage); output.Flush(flushToDisk: true); }
            File.Move(temporary, backupPath, overwrite: false);
            MarkPreimageReadOnly(backupPath);
        }
        catch (Exception failure) when (failure is IOException or UnauthorizedAccessException)
        {
            try { File.Delete(temporary); }
            catch (Exception cleanup) when (cleanup is IOException or UnauthorizedAccessException)
            { throw new AggregateException("Identity preimage commit and temporary-file cleanup failed.", failure, cleanup); }
            throw;
        }
    }

    private static void MarkPreimageReadOnly(string path) =>
        File.SetAttributes(path, File.GetAttributes(path) | FileAttributes.ReadOnly);
}

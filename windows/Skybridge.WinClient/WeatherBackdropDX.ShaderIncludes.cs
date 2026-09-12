using System.IO;
using SharpGen.Runtime;
using Vortice.Direct3D;

namespace Skybridge.WinClient;

public sealed partial class WeatherBackdropDX
{
    // Weather shaders are embedded, self-contained sources. The flags-aware FXC
    // API requires an include handler; no working-directory file lookup is needed.
    private sealed class WeatherShaderIncludes : CallbackBase, Include
    {
        public Stream Open(IncludeType type, string fileName, Stream? parentStream) =>
            throw new InvalidDataException($"Embedded weather shaders cannot include '{fileName}'.");

        public void Close(Stream stream) => stream.Dispose();
    }
}

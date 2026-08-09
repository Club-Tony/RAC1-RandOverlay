using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Reflection;
using System.Security.Cryptography;

internal static class RandOverlayBootstrap
{
    private const string ExpectedPayloadSha256 = "__PAYLOAD_SHA256__";

    private static string Quote(string value)
    {
        return "\"" + value.Replace("\"", "\\\"") + "\"";
    }

    private static string HashFile(string path)
    {
        using (var stream = File.OpenRead(path))
        using (var sha = SHA256.Create())
            return BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "");
    }

    public static int Main(string[] args)
    {
        Console.Title = "RandOverlay Vulkan Setup";
        var temp = Path.Combine(Path.GetTempPath(), "RandOverlaySetup-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(temp);
        try
        {
            var zip = Path.Combine(temp, "RandOverlay.zip");
            using (var input = Assembly.GetExecutingAssembly().GetManifestResourceStream("payload.zip"))
            using (var output = File.Create(zip))
            {
                if (input == null) throw new InvalidOperationException("Embedded release payload is missing.");
                input.CopyTo(output);
            }
            if (!String.Equals(HashFile(zip), ExpectedPayloadSha256, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Embedded release payload failed SHA-256 verification.");

            var expanded = Path.Combine(temp, "expanded");
            ZipFile.ExtractToDirectory(zip, expanded);
            var setup = Directory.GetFiles(expanded, "Setup-RandOverlay.ps1", SearchOption.AllDirectories).FirstOrDefault();
            if (setup == null) throw new InvalidOperationException("Setup-RandOverlay.ps1 is missing from the release payload.");

            var argumentLine = "-NoProfile -File " + Quote(setup);
            if (args.Length > 0) argumentLine += " " + String.Join(" ", args.Select(Quote));
            var process = Process.Start(new ProcessStartInfo
            {
                FileName = Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe"),
                Arguments = argumentLine,
                UseShellExecute = false
            });
            if (process == null) throw new InvalidOperationException("PowerShell setup could not be started.");
            process.WaitForExit();
            return process.ExitCode;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine("RandOverlay Setup failed: " + ex.Message);
            Console.WriteLine("Press Enter to close.");
            Console.ReadLine();
            return 1;
        }
        finally
        {
            try { if (Directory.Exists(temp)) Directory.Delete(temp, true); } catch { }
        }
    }
}

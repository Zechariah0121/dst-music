param([switch]$CompileOnly)

# Render-endpoint WASAPI loopback for native-output-timing.test.mjs.
# Process packets in memory and emit only timestamps and synthetic tone matches.
$ErrorActionPreference = 'Stop'
$depDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'helper/native-deps'
$refs = @('System.dll', 'System.Core.dll',
    [Reflection.Assembly]::Load('netstandard, Version=2.0.0.0, Culture=neutral, PublicKeyToken=cc7b13ffcd2ddd51').Location)
foreach ($name in @('NAudio.Core.dll', 'NAudio.Wasapi.dll')) {
    $path = Join-Path $depDir $name
    [Reflection.Assembly]::LoadFrom($path) | Out-Null
    $refs += $path
}

$probe = @'
using System;
using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Threading;
using NAudio.CoreAudioApi;
using NAudio.Wave;

public sealed class NativeOutputTiming {
    // Two tag tones per track plus one marker for each second of source PCM.
    static readonly int[] Frequencies = { 500, 650, 950, 1100, 1250, 1400, 1550, 1700, 1850, 2450, 2750 };
    const int TrackA = 1 | (1 << 9), TrackB = 2 | (1 << 10);
    const int Markers = 127 << 2;
    static readonly CultureInfo Invariant = CultureInfo.InvariantCulture;
    static readonly Guid FloatPcm = new Guid("00000003-0000-0010-8000-00aa00389b71");
    static readonly Guid IntegerPcm = new Guid("00000001-0000-0010-8000-00aa00389b71");
    const int BinsPerTone = 3;
    readonly double[] coefficients = new double[Frequencies.Length * BinsPerTone];
    readonly double[] previous = new double[Frequencies.Length * BinsPerTone];
    readonly double[] older = new double[Frequencies.Length * BinsPerTone];
    readonly int frameSize, sampleBytes, sampleRate, windowFrames;
    readonly bool floatingPoint;
    byte[] packet = new byte[0];
    int framesInWindow, badTimestamps;
    long nextFrame = -1;
    double startMs, nextMs;
    volatile bool stopped;

    NativeOutputTiming(WaveFormat format) {
        var extended = format as WaveFormatExtensible;
        floatingPoint = format.Encoding == WaveFormatEncoding.IeeeFloat || (extended != null && extended.SubFormat == FloatPcm);
        bool integer = format.Encoding == WaveFormatEncoding.Pcm || (extended != null && extended.SubFormat == IntegerPcm);
        sampleBytes = format.BitsPerSample / 8;
        if ((floatingPoint && sampleBytes != 4) || (!floatingPoint && (!integer || sampleBytes < 2 || sampleBytes > 4)))
            throw new InvalidOperationException("Unsupported loopback mix format: " + format);
        frameSize = format.BlockAlign;
        sampleRate = format.SampleRate;
        windowFrames = sampleRate / 50;
        for (int tone = 0; tone < Frequencies.Length; tone++)
            for (int bin = 0; bin < BinsPerTone; bin++)
                coefficients[tone * BinsPerTone + bin] = 2 * Math.Cos(2 * Math.PI * (Frequencies[tone] + (bin - 1) * 50) / sampleRate);
    }

    void Accept(IntPtr buffer, int frames, AudioClientBufferFlags flags, long firstFrame, long qpc100ns) {
        if (qpc100ns == 0 || (flags & AudioClientBufferFlags.TimestampError) != 0) {
            badTimestamps++;
            nextFrame = -1;
            return;
        }
        double firstMs = qpc100ns / 10000.0;
        if (nextFrame != firstFrame || Math.Abs(nextMs - firstMs) > 10) Reset();
        nextFrame = firstFrame + frames;
        nextMs = firstMs + frames * 1000.0 / sampleRate;
        if ((flags & AudioClientBufferFlags.Silent) != 0) {
            Reset();
            return;
        }
        int bytes = frames * frameSize;
        if (packet.Length < bytes) packet = new byte[bytes];
        Marshal.Copy(buffer, packet, 0, bytes);
        for (int offset = 0; offset < bytes; offset += frameSize) {
            if (framesInWindow == 0) startMs = firstMs + (offset / frameSize) * 1000.0 / sampleRate;
            // Both fixture channels carry identical PCM. One channel is enough.
            double sample;
            if (floatingPoint) sample = BitConverter.ToSingle(packet, offset);
            else if (sampleBytes == 2) sample = BitConverter.ToInt16(packet, offset) / 32768.0;
            else if (sampleBytes == 3) sample = (packet[offset] | (packet[offset + 1] << 8) | ((sbyte)packet[offset + 2] << 16)) / 8388608.0;
            else sample = BitConverter.ToInt32(packet, offset) / 2147483648.0;
            for (int i = 0; i < coefficients.Length; i++) {
                double next = sample + coefficients[i] * previous[i] - older[i];
                older[i] = previous[i];
                previous[i] = next;
            }
            if (++framesInWindow == windowFrames) CompleteWindow();
        }
    }

    void Reset() {
        framesInWindow = 0;
        Array.Clear(previous, 0, previous.Length);
        Array.Clear(older, 0, older.Length);
    }

    void CompleteWindow() {
        int mask = 0;
        // The fixture plays each component at about 0.004 peak before endpoint gain.
        double thresholdSquared = Math.Pow(0.00065 * windowFrames / 2, 2);
        for (int tone = 0; tone < Frequencies.Length; tone++) {
            int peak = tone * BinsPerTone + 1;
            double energy = Energy(peak);
            // Require a narrow peak to reduce false matches from other mixed-in audio.
            if (energy >= thresholdSquared && energy >= 4 * Math.Max(Energy(peak - 1), Energy(peak + 1))) mask |= 1 << tone;
        }
        if (((mask & TrackA) == TrackA || (mask & TrackB) == TrackB) && (mask & Markers) != 0)
            Console.WriteLine(string.Format(Invariant, "tone {0:F3} {1}", startMs, mask));
        Reset();
    }

    double Energy(int bin) {
        return previous[bin] * previous[bin] + older[bin] * older[bin] - coefficients[bin] * previous[bin] * older[bin];
    }

    void ReadCommands() {
        string command;
        while ((command = Console.ReadLine()) != null && command != "stop") {
            if (command.StartsWith("ping ", StringComparison.Ordinal)) {
                double now = Stopwatch.GetTimestamp() * 1000.0 / Stopwatch.Frequency;
                Console.WriteLine(string.Format(Invariant, "clock {0} {1:F3}", command.Substring(5), now));
            }
        }
        stopped = true;
    }

    public static void Run() {
        using (var devices = new MMDeviceEnumerator())
        using (var device = devices.GetDefaultAudioEndpoint(DataFlow.Render, Role.Console))
        using (var client = device.AudioClient) {
            var format = client.MixFormat;
            var analyzer = new NativeOutputTiming(format);
            client.Initialize(AudioClientShareMode.Shared, AudioClientStreamFlags.Loopback, 1000000, 0, format, Guid.Empty);
            using (var capture = client.AudioCaptureClient) {
                client.Start();
                Console.WriteLine(string.Format(Invariant, "ready {0} {1} {2}", format.SampleRate, format.Channels, format.BitsPerSample));
                var commands = new Thread(analyzer.ReadCommands) { IsBackground = true };
                commands.Start();
                try {
                    while (!analyzer.stopped) {
                        while (capture.GetNextPacketSize() > 0) {
                            int frames;
                            long deviceFrame, qpc100ns;
                            AudioClientBufferFlags flags;
                            IntPtr buffer = capture.GetBuffer(out frames, out flags, out deviceFrame, out qpc100ns);
                            try { analyzer.Accept(buffer, frames, flags, deviceFrame, qpc100ns); }
                            finally { capture.ReleaseBuffer(frames); }
                        }
                        Thread.Sleep(2);
                    }
                } finally {
                    client.Stop();
                    Console.WriteLine("bad-timestamps " + analyzer.badTimestamps.ToString(Invariant));
                }
            }
        }
    }
}
'@

Add-Type -TypeDefinition $probe -ReferencedAssemblies $refs
if (!$CompileOnly) { [NativeOutputTiming]::Run() }

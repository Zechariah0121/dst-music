using System;
using System.Diagnostics;
using System.Text;

namespace DangoMusic {
    public static class DSPFixtures {
        static void Check(bool condition,string message) {
            if(!condition)throw new Exception(message);
        }
        static double Energy(float[] data,int start) {
            double result=0;for(int i=start;i<data.Length;i++)result+=data[i]*data[i];return result;
        }
        static float[] Signal(int frames,int channels,int frequency,int rate) {
            var data=new float[frames*channels];
            for(int i=0;i<frames;i++)for(int c=0;c<channels;c++)
                data[i*channels+c]=(float)(.2*Math.Sin(2*Math.PI*frequency*i/rate));
            return data;
        }
        static EnvironmentDSP Profile(string region,double rain,int channels,int rate) {
            var dsp=new EnvironmentDSP();dsp.Configure(true,region,false,false,false,rain,1);
            dsp.Process(new float[channels],0,channels,channels,rate);dsp.Reset();return dsp;
        }
        static float[] Render(string region,int channels,int rate) {
            var data=new float[rate*channels*3];data[0]=.5f;
            if(channels==2)data[1]=.5f;
            Profile(region,0,channels,rate).Process(data,0,data.Length,channels,rate);return data;
        }
        static double RainRatio(int frequency) {
            var data=Signal(48000,1,frequency,48000);double dry=Energy(data,1000);
            Profile("surface",1,1,48000).Process(data,0,data.Length,1,48000);
            return Energy(data,1000)/dry;
        }
        // Near-full-scale multitone music, sustained tones, DC, square wave and
        // dense noise expose crest-factor/headroom failures that quiet sine tests miss.
        static float[] DenseSignal(int kind,int rate,int channels,int seconds) {
            var data=new float[rate*channels*seconds];var random=new Random(781);double peak=0;
            for(int i=0;i<rate*seconds;i++)for(int c=0;c<channels;c++) {
                double phase=2*Math.PI*i/rate,value=0;
                if(kind==0) {
                    for(int j=0;j<18;j++)value+=Math.Sin(phase*(131+j*173.31)+j*.73+c*.31)/(1+j*.06);
                    value*=.7+.3*Math.Sin(phase*3.1);
                }
                if(kind==1)value=.8*Math.Sin(phase*997)+.2*Math.Sin(phase*3001);
                if(kind==2)value=1;
                if(kind==3)value=Math.Sin(phase*1000)>=0?1:-1;
                if(kind==4)value=random.NextDouble()*2-1;
                data[i*channels+c]=(float)value;peak=Math.Max(peak,Math.Abs(value));
            }
            for(int i=0;i<data.Length;i++)data[i]=(float)(data[i]*.99/peak);
            return data;
        }
        static double WindowEnergy(float[] data,int first,int last) {
            double result=0;for(int i=first;i<last;i++)result+=data[i]*data[i];return result;
        }
        static string ImmersiveChecks() {
            var log=new StringBuilder();
            foreach(string region in new string[]{"cave","lunar","ocean","ruins","atrium","forest"}) {
                var impulse=Render(region,2,48000);
                double early=WindowEnergy(impulse,96,4800),late=Energy(impulse,4800),longTail=Energy(impulse,48000),side=0;
                for(int i=96;i<impulse.Length;i+=2){double difference=(impulse[i]-impulse[i+1])*.5;side+=2*difference*difference;}
                if(region=="ruins" || region=="forest")Check(late<early*.15,"short warm/dark room tail "+region);
                if(region=="lunar" || region=="atrium")Check(longTail>.005,"large room needs a perceptible long tail "+region);
                if(region=="ocean")Check(late>.02 && longTail<.0001,"ocean sparse open reflections, short decay");
                log.AppendFormat("\n{0}: impulse early 1-50ms={1:F6}, late>50ms={2:F6}, >500ms={3:F6}, side={4:F6}; ",region,early,late,longTail,side);
                for(int kind=0;kind<5;kind++) {
                    var dense=DenseSignal(kind,48000,2,3);double original=Energy(dense,48000);
                    Profile(region,0,2,48000).Process(dense,0,dense.Length,2,48000);
                    double peak=0;int protectedSamples=0;
                    foreach(float value in dense) {
                        Check(!float.IsNaN(value)&&!float.IsInfinity(value)&&Math.Abs(value)<=.980001,"near-full-scale finite headroom "+region);
                        peak=Math.Max(peak,Math.Abs(value));if(Math.Abs(value)>.97999)protectedSamples++;
                    }
                    double ratio=Energy(dense,48000)/original;
                    if(kind==0)Check(ratio>.7 && ratio<1.2,"dense music comparable RMS "+region);
                    log.AppendFormat("fixture{0} RMS={1:F2}dB peak={2:F5} ceiling samples={3}; ",kind,10*Math.Log10(ratio),peak,protectedSamples);
                }
            }
            // Strongest combinations and both ends of the supported rate range.
            foreach(int rate in new int[]{8000,48000,384000})foreach(int channels in new int[]{1,2}) {
                var strongest=Profile("atrium",0,channels,rate);
                var unfiltered=DenseSignal(4,rate,channels,1);
                strongest.Process(unfiltered,0,unfiltered.Length,channels,rate);
                foreach(float value in unfiltered)Check(!float.IsNaN(value)&&!float.IsInfinity(value)&&Math.Abs(value)<=.980001,"full room headroom at rate extremes");
                var dsp=Profile("atrium",1,channels,rate);
                dsp.Configure(true,"atrium",true,true,true,1,1);dsp.Reset();
                var dense=DenseSignal(4,rate,channels,1);dsp.Process(dense,0,dense.Length,channels,rate);
                foreach(float value in dense)Check(!float.IsNaN(value)&&!float.IsInfinity(value)&&Math.Abs(value)<=.980001,"combined flags full strength headroom");
            }
            return log.ToString();
        }

        public static string Run() {
            var log=new StringBuilder();
            string[] regions={"surface","cave","lunar","ocean","ruins","atrium","forest"};
            var tails=new float[regions.Length][];
            for(int r=0;r<regions.Length;r++) {
                tails[r]=Render(regions[r],2,48000);
                double tail=Energy(tails[r],2000);
                Check(r==0?tail==0:tail>.00001,"region tail "+regions[r]);
                log.AppendFormat("{0} tail energy={1:F7}; ",regions[r],tail);
                for(int previous=0;previous<r;previous++) {
                    double delta=0;for(int i=0;i<tails[r].Length;i++)delta+=Math.Abs(tails[r][i]-tails[previous][i]);
                    Check(delta>.01,"regions must differ "+regions[r]+"/"+regions[previous]);
                }
            }
            double low=RainRatio(200),high=RainRatio(8000);
            Check(high<low*.6 && low>.7,"rain frequency-dependent masking");
            log.AppendFormat("rain energy 200Hz={0:F5}, 8kHz={1:F5}. ",low,high);
            double stereoDifference=0;
            for(int i=2000;i<tails[1].Length;i+=2)stereoDifference+=Math.Abs(tails[1][i]-tails[1][i+1]);
            Check(stereoDifference>.01,"stereo room must have a spatial side component");
            Check(Math.Abs(tails[1][0]-.44f)<.000001 && Math.Abs(tails[1][1]-.44f)<.000001,"cave preserves dry stereo attack");
            foreach(string region in regions) {
                var dry=Signal(48000,2,8000,48000);var rain=(float[])dry.Clone();
                Profile(region,0,2,48000).Process(dry,0,dry.Length,2,48000);
                Profile(region,1,2,48000).Process(rain,0,rain.Length,2,48000);
                Check(Energy(rain,2000)<Energy(dry,2000)*.95,"rain stacks on "+region);
                var bassDry=Signal(48000,2,200,48000);var bassRain=(float[])bassDry.Clone();
                Profile(region,0,2,48000).Process(bassDry,0,bassDry.Length,2,48000);
                Profile(region,1,2,48000).Process(bassRain,0,bassRain.Length,2,48000);
                double trebleRatio=Energy(rain,2000)/Energy(dry,2000);
                double bassRatio=Energy(bassRain,2000)/Energy(bassDry,2000);
                Check(trebleRatio<bassRatio*.8,"rain must soften spectrum independently on "+region);
            }
            // Identical target event and source, independent of buffer boundaries.
            var reference=Signal(48000,2,997,48000);
            var referenceDSP=Profile("surface",0,2,48000);
            referenceDSP.Configure(true,"atrium",false,false,false,.7,1);
            referenceDSP.Process(reference,0,reference.Length,2,48000);
            foreach(int frames in new int[]{1,64,480,2048}) {
                var chunked=Signal(48000,2,997,48000);var dsp=Profile("surface",0,2,48000);
                dsp.Configure(true,"atrium",false,false,false,.7,1);
                for(int offset=0;offset<chunked.Length;offset+=frames*2)
                    dsp.Process(chunked,offset,Math.Min(frames*2,chunked.Length-offset),2,48000);
                for(int i=0;i<reference.Length;i++)Check(reference[i]==chunked[i],"buffer-size dependence");
            }
            var polled=Signal(48000,2,997,48000);var pollDSP=Profile("surface",0,2,48000);
            for(int offset=0;offset<polled.Length;offset+=128) {
                pollDSP.Configure(true,"atrium",false,false,false,.7,1);
                pollDSP.Process(polled,offset,Math.Min(128,polled.Length-offset),2,48000);
            }
            for(int i=0;i<reference.Length;i++)Check(reference[i]==polled[i],"identical config must not restart transition");
            var polledDry=Signal(4800,2,997,48000);var pollExpected=(float[])polledDry.Clone();
            for(int offset=0;offset<polledDry.Length;offset+=128) {
                pollDSP.Configure(false,"atrium",false,false,false,1,1);
                pollDSP.Process(polledDry,offset,Math.Min(128,polledDry.Length-offset),2,48000);
            }
            for(int i=7680;i<polledDry.Length;i++)Check(polledDry[i]==pollExpected[i],"identical disable polling must complete fade");
            // Reset and completed fade must both discard tails, including re-enable.
            var reset=Profile("atrium",0,2,48000);var impulse=new float[48000];impulse[0]=.5f;
            reset.Process(impulse,0,impulse.Length,2,48000);reset.Reset();
            var silence=new float[48000];reset.Process(silence,0,silence.Length,2,48000);
            Check(Energy(silence,0)==0,"reset must clear all tails");
            var surface=Profile("atrium",0,2,48000);
            surface.Process(impulse,0,impulse.Length,2,48000);
            surface.Configure(true,"surface",false,false,false,0,1);
            var surfaceFade=new float[9600];surface.Process(surfaceFade,0,surfaceFade.Length,2,48000);
            var surfaceDry=Signal(4800,2,997,48000);var surfaceExpected=(float[])surfaceDry.Clone();
            surface.Process(surfaceDry,0,surfaceDry.Length,2,48000);
            for(int i=0;i<surfaceDry.Length;i++)Check(surfaceDry[i]==surfaceExpected[i],"surface exact dry after fade");
            surface.Configure(true,"atrium",false,false,false,0,1);
            var surfaceZero=new float[48000];surface.Process(surfaceZero,0,surfaceZero.Length,2,48000);
            Check(Energy(surfaceZero,0)==0,"surface must clear old room state");
            foreach(double strength in new double[]{0,1}) {
                var dsp=Profile("atrium",0,2,48000);
                var input=Signal(48000,2,997,48000);dsp.Process(input,0,input.Length,2,48000);
                dsp.Configure(strength==0,"cave",true,true,true,1,strength);
                var fade=Signal(4800,2,997,48000);dsp.Process(fade,0,fade.Length,2,48000);
                var clean=Signal(4800,2,997,48000);var expected=(float[])clean.Clone();
                dsp.Process(clean,0,clean.Length,2,48000);
                for(int i=0;i<clean.Length;i++)Check(clean[i]==expected[i],"settled exact bypass");
                dsp.Configure(true,"atrium",false,false,false,0,1);
                var zero=new float[48000];dsp.Process(zero,0,zero.Length,2,48000);
                Check(Energy(zero,0)==0,"re-enable must not expose stale tail");
            }
            var random=new Random(42);double peak=0,maxJump=0;
            foreach(int rate in new int[]{8000,44100,48000,96000,192000,384000})foreach(int channels in new int[]{1,2}) {
                var dsp=Profile("surface",0,channels,rate);double last=0;bool first=true;
                for(int block=0;block<120;block++) {
                    if(block%3==0)dsp.Configure(true,regions[random.Next(regions.Length)],false,false,false,random.NextDouble(),random.NextDouble());
                    var data=new float[127*channels];
                    for(int i=0;i<127;i++)for(int c=0;c<channels;c++)data[i*channels+c]=(float)(.25*Math.Sin(2*Math.PI*200*(block*127+i)/rate));
                    dsp.Process(data,0,data.Length,channels,rate);
                    for(int i=0;i<data.Length;i++) {
                        Check(!float.IsNaN(data[i])&&!float.IsInfinity(data[i])&&Math.Abs(data[i])<1,"finite unclipped output");
                        peak=Math.Max(peak,Math.Abs(data[i]));
                        if(i%channels==0){if(!first)maxJump=Math.Max(maxJump,Math.Abs(data[i]-last));last=data[i];first=false;}
                    }
                }
            }
            Check(maxJump<.08,"smooth profile transitions on 200Hz signal");
            // Active steady-state stereo benchmark. Buffer and target are preallocated.
            foreach(int frames in new int[]{64,480,2048}) {
                var dsp=Profile("atrium",1,2,48000);var buffer=Signal(frames,2,997,48000);
                for(int i=0;i<100;i++)dsp.Process(buffer,0,buffer.Length,2,48000);
                int iterations=Math.Max(1000,48000*20/frames);int collections=GC.CollectionCount(0);
                var watch=Stopwatch.StartNew();
                for(int i=0;i<iterations;i++)dsp.Process(buffer,0,buffer.Length,2,48000);
                watch.Stop();double audioSeconds=iterations*frames/48000.0;
                double realtime=watch.Elapsed.TotalSeconds/audioSeconds;
                Check(realtime<.5,"DSP benchmark exceeds 50% realtime budget");
                Check(GC.CollectionCount(0)==collections,"steady DSP unexpectedly triggered collection");
                log.AppendFormat("{0}-frame stereo CPU/audio={1:P2}, Gen0=0; ",frames,realtime);
            }
            log.AppendFormat("peak={0:F5}, max adjacent 200Hz jump={1:F5}; mono/stereo 8/44.1/48/96/192/384k, chunk invariance, stereo width, reset, surface cleanup, fades, bypass passed.",peak,maxJump);
            log.Append(ImmersiveChecks());
            return log.ToString();
        }
    }
}





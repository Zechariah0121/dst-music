// Environmental DSP adapted from Sorihiko/DangoMusic EnvironmentAudio.kt,
// commit ffd88ffc9f4b4af30ef7550eb9781468ab180c31 (GPL-3.0).
// See native-deps/SOURCES.md and DangoMusic.LICENSE.txt.
using System;

namespace DangoMusic {
    public sealed class EnvironmentDSP {
        // All delay taps are stationary. Moving between rooms changes weights,
        // never delay length, so transitions cannot bend a singer's pitch.
        const int Lines=8, Taps=12;
        sealed class Target {
            public double Cutoff=20000, FilterMix, Wet, Early, Gain=1, Dry=1, Feedback=.72, Damping=.3, Width=.3;
            public double[] Weights=new double[Lines], Reflections=new double[Taps];
            public bool Bypass=true;
        }
        volatile Target target=new Target();
        Target applied;
        double alpha=1, filterMix, wet, early, gain=1, dry=1, feedback=.72, damping=.3, width=.3;
        double alphaStep, filterStep, wetStep, earlyStep, gainStep, dryStep, feedbackStep, dampingStep, widthStep;
        double targetAlpha, targetDamping, inputLow, limiter=1;
        int rampRemaining, rate, channelCount, earlyPos;
        bool bypass=true;
        readonly double[] low1=new double[2], low2=new double[2];
        readonly double[] combTimes={19.7,27.1,35.3,47.9,61.7,79.3,97.1,127.7};
        readonly double[] earlyTimes={7,11,17,23,31,43,59,73,89,113,139,173};
        readonly int[] combPos=new int[Lines], earlyOffsets=new int[Taps];
        readonly double[] combStore=new double[Lines], weights=new double[Lines], weightStep=new double[Lines];
        readonly double[] reflections=new double[Taps], reflectionStep=new double[Taps];
        double[][] combs;
        double[] earlyBuffer;
        double highpassAlpha, release;

        static double Unit(double value) { return double.IsNaN(value)?0:Math.Max(0,Math.Min(1,value)); }
        void Publish(Target next) {
            var p=target;
            if(p.Bypass==next.Bypass && p.Cutoff==next.Cutoff && p.FilterMix==next.FilterMix &&
                p.Wet==next.Wet && p.Early==next.Early && p.Gain==next.Gain && p.Dry==next.Dry &&
                p.Feedback==next.Feedback && p.Damping==next.Damping && p.Width==next.Width) {
                bool equal=true;
                for(int j=0;j<Lines;j++)equal&=p.Weights[j]==next.Weights[j];
                for(int j=0;j<Taps;j++)equal&=p.Reflections[j]==next.Reflections[j];
                if(equal)return;
            }
            target=next;
        }
        public void Configure(bool enabled,bool water,bool cave,bool indoor,double rain,double strength) {
            Configure(enabled,null,water,cave,indoor,rain,strength);
        }
        public void Configure(bool enabled,string region,bool water,bool cave,bool indoor,double rain,double strength) {
            double s=Unit(strength), r=Unit(rain);
            if(!enabled || s==0){if(!target.Bypass)Publish(new Target());return;}
            var t=new Target();
            // Sparse reflection patterns and distinct late-delay families provide
            // room identity, instead of merely scaling one common small room.
            switch((region??(cave?"cave":"surface")).ToLowerInvariant()) {
                case "cave":
                    SetRoom(t,.48,.30,.84,.32,.65,new double[]{0,0,1,1,1,1,0,0},new int[]{3,5,7},new double[]{.5,-.3,.2});break;
                case "lunar":
                    SetRoom(t,.56,.24,.91,.10,.95,new double[]{0,0,0,0,1,1,1,1},new int[]{5,8,11},new double[]{.4,-.35,.25});break;
                case "ocean":
                    SetRoom(t,.27,.32,.55,.16,1,new double[]{0,1,0,0,1,0,0,1},new int[]{6,9,11},new double[]{.45,-.35,.2});break;
                case "ruins":
                    t.Cutoff=7600;
                    SetRoom(t,.46,.38,.66,.66,.38,new double[]{1,1,1,1,0,0,0,0},new int[]{0,1,2,3},new double[]{.35,-.3,.2,-.15});break;
                case "atrium":
                    t.Cutoff=11000;
                    SetRoom(t,.62,.30,.965,.48,.8,new double[]{0,0,0,1,0,1,1,1},new int[]{6,8,10},new double[]{.4,-.35,.25});break;
                case "forest":
                    t.Cutoff=15000;
                    SetRoom(t,.25,.30,.48,.52,.6,new double[]{1,0,1,0,1,0,0,0},new int[]{1,3,5},new double[]{.5,-.3,.2});break;
            }
            if(indoor){t.Cutoff=Math.Min(t.Cutoff,5000);if(t.Wet==0)SetRoom(t,.4,.3,.7,.5,.45,new double[]{1,1,1,1,0,0,0,0},new int[]{0,2,4},new double[]{.5,-.3,.2});}
            if(water){t.Cutoff=Math.Min(t.Cutoff,450);t.Gain=.85;}
            // Rain acts on the direct source too, retaining low-frequency voice
            // fundamentals while audibly softening consonant/treble energy.
            if(r>0){t.Cutoff*=Math.Pow(6500.0/20000,r);t.Gain*=1-.08*r;}
            t.FilterMix=t.Cutoff<20000?s:0;t.Wet*=s;t.Early*=s;
            t.Dry=1+(t.Dry-1)*s;t.Gain=1+(t.Gain-1)*s;
            t.Bypass=t.Cutoff==20000 && t.Wet==0 && t.Gain==1;
            Publish(t);
        }
        static void SetRoom(Target t,double wet,double early,double feedback,double damping,double width,double[] weights,int[] taps,double[] values) {
            t.Wet=wet;t.Early=early;t.Feedback=feedback;t.Damping=damping;t.Width=width;t.Dry=.88;
            double total=0;foreach(double w in weights)total+=w;
            for(int j=0;j<Lines;j++)t.Weights[j]=weights[j]/total;
            for(int j=0;j<taps.Length;j++)t.Reflections[taps[j]]=values[j];
        }
        void ClearHistory() {
            Array.Clear(low1,0,2);Array.Clear(low2,0,2);
            Array.Clear(combPos,0,Lines);Array.Clear(combStore,0,Lines);
            if(combs!=null)foreach(var c in combs)Array.Clear(c,0,c.Length);
            if(earlyBuffer!=null)Array.Clear(earlyBuffer,0,earlyBuffer.Length);
            earlyPos=0;inputLow=0;limiter=1;
        }
        double FilterDamping(Target t) { return Math.Pow(t.Damping,48000.0/rate); }
        double FilterAlpha(Target t) { return 1-Math.Exp(-2*Math.PI*Math.Min(t.Cutoff,rate*.45)/rate); }
        public void Reset() {
            ClearHistory();applied=target;rampRemaining=0;bypass=applied.Bypass;
            alpha=rate>0?FilterAlpha(applied):1;
            filterMix=applied.FilterMix;wet=applied.Wet;early=applied.Early;gain=applied.Gain;dry=applied.Dry;
            feedback=applied.Feedback;damping=rate>0?FilterDamping(applied):applied.Damping;width=applied.Width;
            Array.Copy(applied.Weights,weights,Lines);Array.Copy(applied.Reflections,reflections,Taps);
        }
        void BeginTransition(Target t) {
            applied=t;targetAlpha=FilterAlpha(t);targetDamping=FilterDamping(t);rampRemaining=Math.Max(1,(int)(rate*.08));
            double scale=1.0/rampRemaining;
            alphaStep=(targetAlpha-alpha)*scale;filterStep=(t.FilterMix-filterMix)*scale;
            wetStep=(t.Wet-wet)*scale;earlyStep=(t.Early-early)*scale;gainStep=(t.Gain-gain)*scale;dryStep=(t.Dry-dry)*scale;
            feedbackStep=(t.Feedback-feedback)*scale;dampingStep=(targetDamping-damping)*scale;widthStep=(t.Width-width)*scale;
            for(int j=0;j<Lines;j++)weightStep[j]=(t.Weights[j]-weights[j])*scale;
            for(int j=0;j<Taps;j++)reflectionStep[j]=(t.Reflections[j]-reflections[j])*scale;
            bypass=false;
        }
        public void Process(float[] pcm,int offset,int count,int channels,int sampleRate) {
            if(channels<1 || channels>2)throw new NotSupportedException("Only mono/stereo audio is supported");
            if(sampleRate<8000 || sampleRate>384000)throw new ArgumentOutOfRangeException("sampleRate");
            if(pcm==null)throw new ArgumentNullException("pcm");
            if(offset<0 || count<0 || count>pcm.Length-offset || count%channels!=0)throw new ArgumentOutOfRangeException("count");
            if(count==0)return;
            if(rate!=sampleRate || channelCount!=channels) {
                rate=sampleRate;channelCount=channels;combs=new double[Lines][];
                for(int j=0;j<Lines;j++)combs[j]=new double[Math.Max(1,(int)(combTimes[j]*rate/1000))];
                for(int j=0;j<Taps;j++)earlyOffsets[j]=Math.Max(1,(int)(earlyTimes[j]*rate/1000));
                earlyBuffer=new double[earlyOffsets[Taps-1]+1];
                highpassAlpha=1-Math.Exp(-2*Math.PI*180/rate);release=1-Math.Exp(-1.0/(rate*.08));Reset();
            }
            var t=target;
            if(!object.ReferenceEquals(t,applied)) {
                if(bypass && t.Bypass){applied=t;return;}BeginTransition(t);
            }
            if(bypass)return;
            bool filtering=filterMix>0 || t.FilterMix>0;
            int end=offset+count;
            for(int i=offset;i<end;i+=channels) {
                if(rampRemaining>0) {
                    alpha+=alphaStep;filterMix+=filterStep;wet+=wetStep;early+=earlyStep;gain+=gainStep;dry+=dryStep;
                    feedback+=feedbackStep;damping+=dampingStep;width+=widthStep;
                    for(int j=0;j<Lines;j++)weights[j]+=weightStep[j];
                    for(int j=0;j<Taps;j++)reflections[j]+=reflectionStep[j];
                    if(--rampRemaining==0) {
                        alpha=targetAlpha;filterMix=t.FilterMix;wet=t.Wet;early=t.Early;gain=t.Gain;dry=t.Dry;
                        feedback=t.Feedback;damping=targetDamping;width=t.Width;
                        Array.Copy(t.Weights,weights,Lines);Array.Copy(t.Reflections,reflections,Taps);
                        if(t.Bypass){ClearHistory();bypass=true;return;}
                    }
                }
                double left=pcm[i],right=channels==2?pcm[i+1]:left;
                if(filtering) {
                    low1[0]+=alpha*(left-low1[0]);low2[0]+=alpha*(low1[0]-low2[0]);left+=(low2[0]-left)*filterMix;
                    if(channels==2){low1[1]+=alpha*(right-low1[1]);low2[1]+=alpha*(low1[1]-low2[1]);right+=(low2[1]-right)*filterMix;}else right=left;
                }
                double mid=0,side=0;
                if(wet>0 || early>0)Reverb((left+right)*.5,out mid,out side);
                left=(left*dry+mid+side*width)*gain;right=(right*dry+mid-side*width)*gain;
                // Linked, immediate peak protection with an 80ms recovery. It is
                // inactive below .98 and does not flatten samples with clipping.
                double peak=Math.Max(Math.Abs(left),Math.Abs(right));
                double ceiling=peak>.98?.98/peak:1;
                limiter=Math.Min(ceiling,limiter+(1-limiter)*release);
                pcm[i]=(float)(left*limiter);if(channels==2)pcm[i+1]=(float)(right*limiter);
            }
        }
        void Reverb(double input,out double mid,out double side) {
            inputLow+=highpassAlpha*(input-inputLow);input-=inputLow;
            double sum=0,difference=0,undamped=1-damping;
            for(int j=0;j<Lines;j++) {
                int p=combPos[j];double delayed=combs[j][p];
                combStore[j]=delayed*undamped+combStore[j]*damping;
                combs[j][p]=input*.65+combStore[j]*feedback;
                combPos[j]=p+1==combs[j].Length?0:p+1;
                double value=delayed*weights[j];sum+=value;difference+=(j%2==0?value:-value);
            }
            mid=sum*wet;side=difference*wet*.75;
            earlyBuffer[earlyPos]=input;
            for(int j=0;j<Taps;j++) {
                int p=earlyPos-earlyOffsets[j];if(p<0)p+=earlyBuffer.Length;
                double value=earlyBuffer[p]*reflections[j]*early;
                mid+=value;side+=(j%2==0?value:-value);
            }
            if(++earlyPos==earlyBuffer.Length)earlyPos=0;
        }
        public static double NormalizedGain(bool enabled,double gainDb,double peak) {
            if(!enabled||gainDb==0)return 1;
            double g=Math.Pow(10,gainDb/20);if(peak>0)g=Math.Min(g,.98/peak);
            return Math.Max(.25,Math.Min(2,g));
        }
    }
}


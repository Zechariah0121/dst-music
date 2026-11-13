import {readFile,writeFile,rename} from 'node:fs/promises';
import {resolve} from 'node:path';
const boolean=(value,consumer='mod')=>({type:'boolean',default:value,consumer});
const number=(value,min,max,integer=false,consumer='mod')=>({type:'number',default:value,min,max,integer,consumer});
const unsupported=(field,reason)=>({...field,supported:false,reason});
export const SETTINGS_SCHEMA={
 lyrics:{
  enabled:boolean(true),worldMode:boolean(true),nowPlaying:boolean(false),showCover:boolean(true),scale:number(1,.5,3),distance:number(10,3,40),
  glow:boolean(true),glowNightOnly:boolean(false),glowColor:number(0,0,3,true),glowStrength:number(.3,0,3),glowRadius:number(.5,0,1),
  smoothFont:boolean(false),wiggle:boolean(true),wiggleFps:number(8,4,24,true),wiggleAmount:number(.8,0,2),
  textFlash:boolean(false),wordPop:boolean(true),flashSize:number(1,.5,2),facePlayer:boolean(true),keepAway:boolean(true),stayOnScreen:boolean(false),aboveGround:boolean(false),spread:number(30,0,60),splitLines:boolean(true),
  translation:boolean(false),translationAnimation:boolean(true),translationWiggle:boolean(true),
  dance:unsupported(boolean(false),'当前移植版不修改生物实体动画，未实现生物舞蹈'),
  danceAuto:unsupported(boolean(false),'当前原生音频后端尚无自动BPM分析'),
  danceTap:unsupported(boolean(false),'未实现生物舞蹈，因此不提供手动打拍'),
  danceSpin:unsupported(boolean(false),'当前移植版不旋转生物实体'),
  danceAmount:unsupported(number(1.3,.2,2),'未实现生物舞蹈，律动幅度无可用消费者'),
  danceOffset:unsupported(number(0,-300,300,true),'未实现生物舞蹈，节拍偏移无可用消费者'),
  danceBpm:unsupported(number(120,40,240),'未实现生物舞蹈，BPM值无可用消费者'),
  textColor:number(0xF7E1D7,0,0xffffff,true),translationColor:number(0x803D66,0,0xffffff,true),
 },
 player:{
  showTopLeftButton:boolean(true),
  musicSource:number(0,0,1,true,'backend'),volume:number(.7,0,1,false,'backend'),language:unsupported(number(-1,-1,1,true),'当前游戏播放器尚未实现中英文界面切换；歌词翻译使用独立开关'),shuffle:boolean(false,'backend'),repeatOne:boolean(false,'backend'),
  openKey:number(0,0,511,true),keyPause:number(0,0,511,true),keyPrev:number(0,0,511,true),keyNext:number(0,0,511,true),keyVolUp:number(0,0,511,true),keyVolDown:number(0,0,511,true),keyLyrics:number(0,0,511,true),normalize:boolean(true,'backend'),
  envAudio:boolean(true,'native-dsp'),envWater:boolean(true,'native-dsp'),envCave:boolean(true,'native-dsp'),envIndoor:boolean(true,'native-dsp'),
  envLunar:boolean(true,'native-dsp'),envOcean:boolean(true,'native-dsp'),envRuins:boolean(true,'native-dsp'),envAtrium:boolean(true,'native-dsp'),envForest:boolean(true,'native-dsp'),
  envRain:boolean(true,'native-dsp'),envStrength:number(1,0,1,false,'native-dsp'),
  checkUpdates:boolean(true,'backend'),
 },
 card:{enabled:boolean(true),scale:number(1,.6,2),showPaused:boolean(false),posX:number(.01,0,1),posY:number(.05,0,1)},
 island:{enabled:boolean(true),glass:boolean(true),showMusic:boolean(true),songNotify:boolean(true),scale:number(1,.6,1.6),notifyTime:number(3.5,1,8)},
};
export const DEFAULT_SETTINGS=Object.fromEntries(Object.entries(SETTINGS_SCHEMA).map(([group,fields])=>[group,Object.fromEntries(Object.entries(fields).map(([key,field])=>[key,field.default]))]));
const invalid=message=>Object.assign(new Error(message),{status:422});
function isObject(value){return !!value&&typeof value==='object'&&!Array.isArray(value);}
export function validateSettingsPatch(patch,{allowUnsupported=false}={}) {
 if(!isObject(patch)||Object.keys(patch).length===0)throw invalid('设置不能为空');
 const out={};
 for(const [group,fields]of Object.entries(patch)) {
  if(!Object.hasOwn(SETTINGS_SCHEMA,group)||!isObject(fields)||!Object.keys(fields).length)throw invalid('设置分组无效');
  out[group]={};
  for(const[key,value]of Object.entries(fields)) {
   const schema=SETTINGS_SCHEMA[group][key];if(!schema||!Object.hasOwn(SETTINGS_SCHEMA[group],key))throw invalid('设置字段不存在');
   if(typeof value!==schema.type||(schema.type==='number'&&(!Number.isFinite(value)||value<schema.min||value>schema.max||(schema.integer&&!Number.isInteger(value)))))throw invalid(`设置 ${group}.${key} 的值无效`);
   if(!allowUnsupported&&schema.supported===false&&value!==schema.default)throw invalid(schema.reason);
   out[group][key]=value;
  }
 }
 return out;
}
export async function createSettingsStore(stateDir) {
 const path=resolve(stateDir,'settings.json');
 let settings=structuredClone(DEFAULT_SETTINGS),revision=0;
 try {
  const saved=JSON.parse(await readFile(path,'utf8')),patch=validateSettingsPatch(saved.settings,{allowUnsupported:true});
  settings=Object.fromEntries(Object.keys(settings).map(group=>[group,{...settings[group],...patch[group]}]));
  revision=Number.isSafeInteger(saved.revision)&&saved.revision>=0?saved.revision:0;
 }catch(error){if(error.code!=='ENOENT')throw invalid('本机设置文件损坏，请检查 settings.json');}
 return{
  read:()=>({settings:structuredClone(settings),settingsRevision:revision}),
  async patch(input){
   const patch=validateSettingsPatch(input);
   const next=Object.fromEntries(Object.keys(settings).map(group=>[group,{...settings[group],...patch[group]}]));
   if(next.player.shuffle&&next.player.repeatOne)throw invalid('随机播放和单曲循环不能同时启用');
   if(JSON.stringify(next)!==JSON.stringify(settings)) {
    await writeFile(path+'.tmp',JSON.stringify({settings:next,revision:revision+1},null,2),{mode:0o600});await rename(path+'.tmp',path);
    settings=next;revision++;
   }
   return this.read();
  },
 };
}

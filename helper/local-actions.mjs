import {spawn} from 'node:child_process';
import {lstat} from 'node:fs/promises';
import {dirname,join,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

const failure=message=>Object.assign(new Error(message),{status:422});
const openerPath=fileURLToPath(new URL('./Open-ModFolder.ps1',import.meta.url));

async function isModDirectory(directory) {
  if(!(await lstat(directory)).isDirectory() || !(await lstat(join(directory,'modinfo.lua'))).isFile())return false;
  for(let parent=dirname(directory);parent!==dirname(parent);parent=dirname(parent)) {
    if(!(await lstat(parent)).isDirectory())return false;
  }
  return true;
}

// The request never supplies a path or command. The launcher supplies the
// installed mod directory once when starting this loopback-only service.
export function createModFolderOpener(modDirectory,{spawnImpl=spawn,platform=process.platform}={}) {
  const directory=resolve(modDirectory);
  return async function openModFolder() {
    if(platform!=='win32')throw failure('此入口目前仅支持 Windows');
    if(!(await isModDirectory(directory).catch(()=>false))) {
      throw failure('未找到已连接的模组目录，请重新运行一键启动播放器');
    }
    return new Promise((accept,reject)=>{
      const onFailure=()=>reject(failure('无法打开模组目录，请在 Steam 中浏览游戏文件'));
      const executable=join(process.env.SystemRoot || 'C:\\Windows','System32','WindowsPowerShell','v1.0','powershell.exe');
      const child=spawnImpl(executable,[
        '-NoProfile','-NonInteractive','-STA','-ExecutionPolicy','Bypass','-File',openerPath,
      ],{shell:false,stdio:'ignore',windowsHide:true,timeout:6500,env:{...process.env,DST_MUSIC_MOD_FOLDER:directory}});
      child.once('error',onFailure);
      child.once('exit',code=>{
        if(code===0 || code===10)accept({opened:true,focused:code===0});
        else if(code===11)reject(failure('未能确认模组目录已打开，请按 Alt+Tab 查看，或在 Steam 中浏览游戏文件'));
        else onFailure();
      });
    });
  };
}

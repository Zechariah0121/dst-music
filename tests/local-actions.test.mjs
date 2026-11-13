import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,mkdir,writeFile,rm,symlink} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import {tmpdir} from 'node:os';
import {EventEmitter} from 'node:events';
import {createModFolderOpener} from '../helper/local-actions.mjs';

test('目录入口向固定脚本传入已校验的目录，并报告前台激活状态',async t=>{
  const root=await mkdtemp(join(tmpdir(),'dst-folder-'));
  t.after(()=>rm(root,{recursive:true,force:true}));
  const dir=join(root,"Don't Starve 模组");
  await mkdir(dir);
  await writeFile(join(dir,'modinfo.lua'),'name="test"');
  const calls=[];
  function openWithResult(code) {
    return createModFolderOpener(dir,{platform:'win32',spawnImpl:(exe,args,options)=>{
      calls.push({exe,args,options});
      const child=new EventEmitter();
      queueMicrotask(()=>{
        child.emit('spawn');
        if(code==='error')child.emit('error',new Error('fixture'));
        else child.emit('exit',code);
      });
      return child;
    }})();
  }
  assert.deepEqual(await openWithResult(0),{opened:true,focused:true});
  assert.deepEqual(await openWithResult(10),{opened:true,focused:false});
  await assert.rejects(openWithResult(11),{status:422,message:/未能确认模组目录已打开.*Alt\+Tab/});
  await assert.rejects(openWithResult(1),{status:422});
  await assert.rejects(openWithResult(null),{status:422});
  await assert.rejects(openWithResult('error'),{status:422});
  const [{exe,args,options}]=calls;
  assert.match(exe,/powershell\.exe$/);
  assert.match(args.at(-1),/Open-ModFolder\.ps1$/);
  assert.ok(!args.includes(dir));
  assert.equal(options.env.DST_MUSIC_MOD_FOLDER,resolve(dir));
  assert.equal(options.shell,false);
  assert.equal(options.windowsHide,true);

  await assert.rejects(createModFolderOpener(join(dir,'missing'),{platform:'win32'})(),{status:422});
  const linked=join(root,'linked');
  await symlink(dir,linked,process.platform==='win32'?'junction':'dir');
  await assert.rejects(createModFolderOpener(linked,{platform:'win32'})(),{status:422});
});

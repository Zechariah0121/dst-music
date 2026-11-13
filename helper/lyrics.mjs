// Timestamp parsers; no word timing is synthesized from line-only sources.
const MAX_SECONDS = 86400;
function input(text) { return typeof text === 'string' ? text.slice(0, 2_000_000).split(/\r?\n/).slice(0,20000) : []; }
const valid = n => Number.isFinite(n) && n >= 0 && n <= MAX_SECONDS;
const placeholder = text => /^(?:纯音乐(?:[，,\s]*请(?:您)?欣赏)?|instrumental)$/i.test(text.trim());
export function parseLrc(text, duration = 0) {
  const rows = input(text), offset = Number(/\[offset:([+-]?\d+)\]/i.exec(typeof text === 'string' ? text : '')?.[1] || 0) / 1000;
  const lines = [];
  for (const row of rows) {
    let rest=row.trim(); const starts=[];
    for (;;) {
      const tag=/^\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]/.exec(rest);
      if(!tag)break;
      const start=Number(tag[1])*60+Number(tag[2])+Number('0.'+(tag[3]||'0'))+offset;
      if(Number(tag[2])<60 && valid(start))starts.push(start);
      rest=rest.slice(tag[0].length);
    }
    const content=rest.trim();
    if(!content||placeholder(content))continue;
    for(const start of starts)lines.push({start,end:0,text:content,words:[]});
  }
  lines.sort((a,b)=>a.start-b.start);
  let next;
  for(let i=lines.length-1;i>=0;i--) {
    if(i+1<lines.length&&lines[i+1].start>lines[i].start)next=lines[i+1].start;
    // Line-only sources provide no final-line end. Track duration is preferred;
    // otherwise a bounded display tail is explicit line timing, never word timing.
    lines[i].end=next ?? (valid(duration)&&duration>lines[i].start ? duration : lines[i].start+5);
  }
  return lines;
}
export function parseYrc(text) {
  const lines=[];
  for(const row of input(text)) {
    const line=/^\[(\d+),(\d+)\](.*)$/.exec(row.trim());if(!line)continue;
    const start=Number(line[1])/1000,end=start+Number(line[2])/1000;
    if(!valid(start)||!valid(end)||end<start)continue;
    const tags=[...line[3].matchAll(/\((\d+),(\d+),\d+\)/g)],words=[];
    for(let i=0;i<tags.length;i++) {
      const tag=tags[i],wordStart=Number(tag[1])/1000,wordEnd=wordStart+Number(tag[2])/1000;
      const content=line[3].slice(tag.index+tag[0].length,tags[i+1]?.index ?? line[3].length);
      if(content && valid(wordStart)&&valid(wordEnd)&&wordStart>=start&&wordEnd<=end+0.001&&wordEnd>=wordStart)words.push({start:wordStart,end:wordEnd,text:content});
    }
    words.sort((a,b)=>a.start-b.start);
    const content=words.map(w=>w.text).join('').trim();
    if(content&&!placeholder(content))lines.push({start,end,text:content,words});
  }
  return lines.sort((a,b)=>a.start-b.start);
}
export function parseLyrics(raw, duration = 0) {
  let lines=parseYrc(raw?.yrc?.lyric);
  const timing=lines.length?'word':'line';
  if(!lines.length)lines=parseLrc(raw?.lrc?.lyric,duration);
  const translations=parseLrc(raw?.ytlrc?.lyric || raw?.tlyric?.lyric).filter(t=>t.text!=='//'&&/[\p{L}\p{N}]/u.test(t.text));
  for(const line of lines) {
    let low=0,high=translations.length;
    while(low<high){const middle=(low+high)>>1;if(translations[middle].start<line.start)low=middle+1;else high=middle;}
    const nearest=[translations[low-1],translations[low]].filter(Boolean).reduce((best,t)=>!best||Math.abs(t.start-line.start)<Math.abs(best.start-line.start)?t:best,null);
    if(nearest&&nearest.text!==line.text&&Math.abs(nearest.start-line.start)<=1.5)line.translation=nearest.text;
  }
  return{lines,timing:lines.length?timing:'none'};
}

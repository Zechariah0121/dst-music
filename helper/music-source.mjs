// Source-qualified public IDs keep QQ and legacy NetEase caches independent.
export function musicId(value) {
  const id = String(value ?? '');
  if (/^[1-9]\d{0,15}$/.test(id) && Number.isSafeInteger(Number(id))) return id;
  if (/^qq:[A-Za-z0-9]{1,64}$/.test(id) || /^qq:(?:playlist|chart|liked):[1-9]\d{0,18}$/.test(id)) return id;
  throw Object.assign(new Error('歌曲或歌单编号无效'), {status:400});
}
export function providerForId(value) { return musicId(value).startsWith('qq:') ? 'qq' : 'netease'; }
export function musicProvider(value) {
  if (value === 'netease' || value === 'qq') return value;
  throw Object.assign(new Error('音乐来源无效'), {status:400});
}
export const providerLabel = provider => provider === 'qq' ? 'QQ 音乐' : '网易云音乐';

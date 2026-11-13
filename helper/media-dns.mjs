import {isIP} from 'node:net';

const RESOLVERS=['https://dns.alidns.com/resolve','https://cloudflare-dns.com/dns-query'];
const failure=()=>Object.assign(new Error('音频域名解析失败，请检查代理或网络后重试'),{status:502});
export function publicMediaAddress(ip) {
 if(isIP(ip)!==4)return false;
 const [a,b]=ip.split('.').map(Number);
 return !(a===0||a===10||a===127||a>=224||(a===169&&b===254)||(a===172&&b>=16&&b<=31)||(a===192&&b===168)||(a===100&&b>=64&&b<=127)||(a===198&&(b===18||b===19)));
}
export function proxyFakeAddress(ip) {
 return isIP(ip)===4 && /^198\.(?:18|19)\./.test(ip);
}

export function qqMediaHostname(hostname) {
 return /^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*stream\.qqmusic\.qq\.com$/i.test(hostname);
}

// TUN proxies commonly answer system DNS with 198.18/15 synthetic addresses.
// Resolve only the already-validated CDN hostname over authenticated HTTPS;
// keep rejecting synthetic/private addresses and pin the real IP on the request.
// No cookies, tokens, track IDs or media paths are sent to DNS providers.
export function createPublicMediaResolver({fetchImpl=fetch,now=Date.now}={}) {
 const cache=new Map();
 return async function resolve(hostname,callerSignal) {
  if(!/^[a-z0-9.-]+\.music\.126\.net$/i.test(hostname)&&!qqMediaHostname(hostname))throw failure();
  callerSignal?.throwIfAborted();
  const key=hostname.toLowerCase(),entry=cache.get(key);
  if(entry&&entry.expires>now())return entry.addresses;
  cache.delete(key);
  const cancel=new AbortController();
  const shared=callerSignal?AbortSignal.any([callerSignal,cancel.signal]):cancel.signal;
  async function query(endpoint) {
    shared.throwIfAborted();
    const signal=AbortSignal.any([shared,AbortSignal.timeout(8000)]);
    const url=new URL(endpoint);url.searchParams.set('name',key);url.searchParams.set('type','A');
    const response=await fetchImpl(url,{headers:{Accept:'application/dns-json'},credentials:'omit',redirect:'error',signal});
    if(!response.ok){await response.body?.cancel();throw failure();}
    const chunks=[];let bytes=0;
    for await(const chunk of response.body) {
     bytes+=chunk.length;if(bytes>65536)throw failure();chunks.push(chunk);
    }
    const data=JSON.parse(Buffer.concat(chunks).toString('utf8'));
    if(data.Status!==0||!data.Question?.some(q=>q.type===1&&String(q.name).toLowerCase().replace(/\.$/,'')===key))throw failure();
    const answers=Array.isArray(data.Answer)?data.Answer.filter(a=>a.type===1):[];
    if(!answers.length||answers.some(a=>!publicMediaAddress(a.data)))throw failure();
    const addresses=[...new Set(answers.map(a=>a.data))].map(address=>({address,family:4}));
    const ttl=Math.min(60,...answers.map(a=>Number.isFinite(a.TTL)&&a.TTL>0?a.TTL:0));
    return{addresses,ttl};
  }
  // A slow primary DNS lookup should not add its entire timeout to every song.
  // The secondary is hedged after 250ms (or immediately on a failed primary).
  // Only a fully validated answer wins; abort the other request before returning.
  let startSecondary;
  const start=new Promise(resolve=>{startSecondary=resolve;});
  const hedge=setTimeout(startSecondary,250);
  try {
    const primary=query(RESOLVERS[0]).catch(error=>{startSecondary();throw error;});
    const secondary=start.then(()=>query(RESOLVERS[1]));
    const {addresses,ttl}=await Promise.any([primary,secondary]);
    if(ttl>0){
     if(cache.size>=64)cache.delete(cache.keys().next().value);
     cache.set(key,{addresses,expires:now()+ttl*1000});
    }
    return addresses;
  }catch{
    if(callerSignal?.aborted)callerSignal.throwIfAborted();
    throw failure();
  }finally{clearTimeout(hedge);cancel.abort();startSecondary();}
 };
}

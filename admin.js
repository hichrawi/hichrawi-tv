import { initializeApp } from "https://www.gstatic.com/firebasejs/12.16.0/firebase-app.js";
import { getAuth, signInWithEmailAndPassword, onAuthStateChanged, signOut } from "https://www.gstatic.com/firebasejs/12.16.0/firebase-auth.js";
import { getFirestore, collection, getDocs, addDoc, deleteDoc, doc, setDoc, getDoc, updateDoc } from "https://www.gstatic.com/firebasejs/12.16.0/firebase-firestore.js";
import { getStorage, ref, uploadBytes, getDownloadURL, deleteObject } from "https://www.gstatic.com/firebasejs/12.16.0/firebase-storage.js";
import { firebaseConfig } from "./admin-config.js";

const app = initializeApp(firebaseConfig);
const auth = getAuth(app);
const db = getFirestore(app);

// Railway stream engine API
const STREAM_ENGINE_URL = "https://hichrawi-tv-production.up.railway.app";
// ================= HICHRAWI V2 SOURCE TYPES =================
// Supported universal source types:
// iptv / hls / m3u8 / m3u / direct_video / mp4 / radio / mp3 / aac / rtmp / rtsp / youtube / videos

window.HICHRAWI_SOURCE_TYPES = [
  {value:"iptv", label:"📡 IPTV / M3U8"},
  {value:"m3u", label:"📋 M3U Playlist"},
  {value:"direct_video", label:"🎞️ رابط فيديو مباشر"},
  {value:"radio", label:"📻 Radio / MP3 / AAC"},
  {value:"rtmp", label:"🔴 RTMP"},
  {value:"rtsp", label:"🟣 RTSP"},
  {value:"youtube", label:"▶️ YouTube"},
  {value:"videos", label:"🎬 فيديوهاتي / Playlist"}
];

window.getHichrawiSourceTypeLabel = function(type){
  const x = HICHRAWI_SOURCE_TYPES.find(v=>v.value===type);
  return x ? x.label : type;
};


const sourceStatusStyle = document.createElement("style");
sourceStatusStyle.textContent = `
#sourceSwitchStatus{
  margin:14px 0 0;padding:13px 16px;border-radius:10px;
  background:#1b1b1b;border:1px solid #444;color:#ddd;
  font-weight:700;line-height:1.7;display:none
}
#sourceSwitchStatus.pending{display:block;border-color:#d99f00;color:#ffd45a}
#sourceSwitchStatus.success{display:block;border-color:#21a366;color:#52e58f}
#sourceSwitchStatus.error{display:block;border-color:#c0392b;color:#ff7b72}
`;
document.head.appendChild(sourceStatusStyle);

const storage = getStorage(app);

// دخول الإدارة
document.getElementById("loginBtn")?.addEventListener("click", async ()=>{
 try{
  await signInWithEmailAndPassword(
   auth,
   document.getElementById("loginEmail").value,
   document.getElementById("loginPassword").value
  );
 }catch(e){
  document.getElementById("loginError").innerHTML="❌ الإيميل أو كلمة السر خاطئة";
 }
});

onAuthStateChanged(auth,(user)=>{
 const box=document.getElementById("loginBox");
 if(user){
  if(box) box.style.display="none";
 loadChannels();
loadVideos();
  loadServerVideos();
  loadStreamSettings();
  loadAnnouncement();
   loadSettings();
   loadBroadcastSources();
   refreshViewerStats();
   refreshLiveDashboard();
   if(!window.__hichrawiAdminPollingStarted){
     window.__hichrawiAdminPollingStarted = true;
     window.__hichrawiAdminPolling = setInterval(()=>{
       refreshViewerStats();
       refreshLiveDashboard();
       loadBroadcastSources();
     },10000);
   }
 }else{
  if(box) box.style.display="flex";
  if(window.__hichrawiAdminPolling){
    clearInterval(window.__hichrawiAdminPolling);
    window.__hichrawiAdminPolling = null;
    window.__hichrawiAdminPollingStarted = false;
  }
 }
});

document.querySelector(".logout")?.addEventListener("click",()=>signOut(auth));


// فتح نافذة إضافة قناة
window.openAddChannel=()=>{
 const m=document.getElementById("channelModal");
 if(m) m.style.display="flex";
};

window.closeChannel=()=>{
 const m=document.getElementById("channelModal");
 if(m) m.style.display="none";
};


// إضافة قناة
window.saveChannel=async()=>{
 const name=document.getElementById("newChannelName").value;
 const logo=document.getElementById("newChannelLogo").value;
 const stream=document.getElementById("newChannelStream").value;
 const status=document.getElementById("newChannelStatus").value;

 if(!name || !stream){
  alert("أدخل اسم القناة ورابط البث");
  return;
 }

 await addDoc(collection(db,"channels"),{
  name,logo,stream,status,
  createdAt:new Date()
 });

 alert("تمت إضافة القناة");
 closeChannel();
 loadChannels();
};


// عرض القنوات
async function loadChannels(){
 const table=document.getElementById("channelsTable");
 if(!table)return;

 table.innerHTML="";

 const snap=await getDocs(collection(db,"channels"));
 let count=0;

 snap.forEach(item=>{
  count++;
  const d=item.data();

  table.innerHTML+=`
  <tr>
   <td><img src="${d.logo||''}" width="50"></td>
   <td>${d.name||""}</td>
   <td>${d.stream||""}</td>
   <td>${d.status||""}</td>
   <td><button onclick="deleteChannel('${item.id}')">🗑 حذف</button></td>
  </tr>`;
 });

 document.getElementById("channelsCount").innerText=count;
}

window.deleteChannel=async(id)=>{
 if(confirm("حذف القناة؟")){
  await deleteDoc(doc(db,"channels",id));
  loadChannels();
 }
};



// ================= BROADCAST SOURCE MANAGER =================
// Saves source definitions in Firestore. The active source is also written to
// settings/stream as requestedSource/sourceType. The existing IPTV runtime
// remains untouched until the server-side source engine is connected.

function sourceTypeLabel(type){
  const labels = {
    iptv:"📡 IPTV / M3U8",
    m3u:"📋 M3U Playlist",
    direct_video:"🎞️ فيديو مباشر",
    radio:"📻 Radio / MP3 / AAC",
    rtmp:"🔴 RTMP",
    rtsp:"🟣 RTSP",
    youtube:"▶️ YouTube",
    videos:"🎬 فيديوهاتي / Playlist"
  };
  return labels[type] || ("📡 " + (type || "مصدر"));
}

function sourceTypeName(type){
  const supported = ["iptv","m3u","direct_video","radio","rtmp","rtsp","youtube","videos"];
  return supported.includes(type) ? type : "iptv";
}

window.saveHichrawiSource = async({name,type,url,libraryId})=>{
  const cleanName = (name || "").trim();
  const cleanUrl = (url || "").trim();

  if(!cleanName){
    throw new Error("اسم المصدر مطلوب");
  }

  if(type !== "videos" && !cleanUrl){
    throw new Error("رابط المصدر مطلوب");
  }

  await addDoc(collection(db,"broadcastSources"),{
    name: cleanName,
    type: sourceTypeName(type),
    url: cleanUrl,
    libraryId: type === "videos" ? (libraryId || "") : "",
    enabled: false,
    active: false,
    createdAt: new Date()
  });

  await loadBroadcastSources();
};


async function syncSourceStatusFromEngine(){
  try{
    const r = await fetch(STREAM_ENGINE_URL + "/api/status?ts=" + Date.now(), {cache:"no-store"});
    if(!r.ok) return null;
    const state = await r.json();
    const name = String(state.source_name || "").trim();
    const type = String(state.source_type || "").trim().toLowerCase();
    if(name){
      updateActiveSourceUI({name, type});
    }
    return state;
  }catch(e){
    console.warn("syncSourceStatusFromEngine", e);
    return null;
  }
}


async function loadFallbackSelector(sourcesSnap, fallbackState={}){
  const select=document.getElementById("fallbackSourceSelect");
  if(!select) return;
  const currentId=String(fallbackState?.fallback?.sourceId||"");
  const currentName=String(fallbackState?.fallback?.name||"");
  select.innerHTML='<option value="">اختر المصدر الاحتياطي</option>';
  let defaultNationalId="";
  sourcesSnap.forEach(item=>{
    const d=item.data();
    const name=String(d.name||"").trim();
    const o=document.createElement("option");
    o.value=item.id;
    o.textContent=name+" — "+(getHichrawiSourceTypeLabel(d.type)||d.type||"");
    select.appendChild(o);
    if(!defaultNationalId && (name==="الوطنية 1" || /الوطنية\s*1/.test(name))) defaultNationalId=item.id;
  });
  if(currentId) select.value=currentId;
  else if(currentName){
    const opt=[...select.options].find(o=>o.textContent.startsWith(currentName+" —"));
    if(opt) select.value=opt.value;
  }
  if(!currentId && !currentName && defaultNationalId){
    try{
      const source=await getSourceDefinitionForSchedule(defaultNationalId);
      await postFallbackSource(source);
      select.value=defaultNationalId;
      const label=document.getElementById("fallbackSourceName");
      if(label) label.textContent=source.name;
    }catch(e){ console.warn("default fallback",e); }
  }
}

window.saveSelectedFallback=async function(){
  try{
    const select=document.getElementById("fallbackSourceSelect");
    const id=select?.value||"";
    if(!id){showSourceSwitchStatus("error","⚠️ اختر مصدرًا احتياطيًا أولاً.");return;}
    const source=await getSourceDefinitionForSchedule(id);
    showSourceSwitchStatus("pending","🟡 جاري حفظ المصدر الاحتياطي: "+source.name);
    await postFallbackSource(source);
    const label=document.getElementById("fallbackSourceName");
    if(label) label.textContent=source.name;
    showSourceSwitchStatus("success","🟢 تم تغيير المصدر الاحتياطي إلى: "+source.name);
    await loadBroadcastSources();
  }catch(e){
    console.error("saveSelectedFallback",e);
    showSourceSwitchStatus("error","🔴 تعذر تغيير المصدر الاحتياطي: "+(e.message||e));
  }
};

async function loadBroadcastSources(){
  const list = document.getElementById("broadcastSourcesList");
  if(!list) return;

  try{
    const sourcesSnap = await getDocs(collection(db,"broadcastSources"));
    const playlistsSnap = await getDocs(collection(db,"playlists"));
    const playlistNames = {};
    playlistsSnap.forEach(p => { playlistNames[p.id] = p.data().name || p.data().title || p.id; });
    const streamSnap = await getDoc(doc(db,"settings","stream"));
    const streamData = streamSnap.exists() ? streamSnap.data() : {};
    let engineState = {};
    try{
      const er = await fetch(STREAM_ENGINE_URL + "/api/status?ts=" + Date.now(), {cache:"no-store"});
      if(er.ok) engineState = await er.json();
    }catch(e){ console.warn("engine status", e); }
    let fallbackState = {};
    try{
      const fr = await fetch(STREAM_ENGINE_URL + "/api/fallback?ts=" + Date.now(), {cache:"no-store"});
      if(fr.ok) fallbackState = await fr.json();
    }catch(e){ console.warn("fallback status", e); }
    await loadFallbackSelector(sourcesSnap, fallbackState);
    const engineName = String(engineState.source_name || "").trim();
    const engineType = String(engineState.source_type || "").trim().toLowerCase();
    const activeId = streamData.activeSourceId || "";
    const fallback = fallbackState.fallback || {};
    const fallbackName = String(fallback.name || "").trim();
    const fallbackType = String(fallback.type || "").trim().toLowerCase();
    const fallbackId = String(fallback.sourceId || "").trim();
    const fallbackLabel = fallbackName || "غير محدد";
    const fallbackUi = document.getElementById("fallbackSourceName");
    if(fallbackUi) fallbackUi.textContent = fallbackLabel;

    if(sourcesSnap.empty){
      list.innerHTML = `
        <div class="source-item">
          <div class="source-item-head">
            <strong>لا توجد مصادر محفوظة</strong>
            <span class="source-badge">متوقف</span>
          </div>
        </div>`;
      updateActiveSourceUI(null);
      return;
    }

    list.innerHTML = "";

    sourcesSnap.forEach(item=>{
      const d = item.data();
      const isActive = (engineName && String(d.name || "").trim() === engineName &&
                        (!engineType || String(d.type || "").toLowerCase() === engineType)) ||
                       (!engineName && item.id === activeId);
      const safeName = String(d.name || "").replace(/</g,"&lt;").replace(/>/g,"&gt;");
      const safeUrl = String(d.url || "").replace(/</g,"&lt;").replace(/>/g,"&gt;");

      list.innerHTML += `
        <div class="source-item ${isActive ? "active" : ""}" data-source-id="${item.id}">
          <div class="source-item-head">
            <strong>${safeName}</strong>
            <span class="source-badge ${isActive ? "active" : ""}">
              ${isActive ? "🟢 يعمل" : "متوقف"}
            </span>
          </div>
          <div class="source-help">
            ${sourceTypeLabel(d.type)}
            ${d.type === "videos" ? " — قائمة: " + (playlistNames[d.libraryId] || d.libraryId || "غير محددة") : (safeUrl ? " — " + safeUrl : "")}
          </div>
          <div class="source-actions">
            <button class="btn add" onclick="startHichrawiSource('${item.id}')">
              ▶️ تشغيل
            </button>
            <button class="btn stop" onclick="stopHichrawiSource('${item.id}')">
              ⏹️ إيقاف
            </button>
            <button class="btn secondary" onclick="setHichrawiFallback('${item.id}')">
              ${((fallbackId && fallbackId===item.id) || (!fallbackId && fallbackName && fallbackName===d.name)) ? "🛡️ احتياطي رئيسي" : "⭐ اجعله احتياطي"}
            </button>
            <button class="btn delete" onclick="deleteHichrawiSource('${item.id}')">
              🗑️ حذف
            </button>
          </div>
        </div>`;
    });

    if(activeId){
      const activeDoc = await getDoc(doc(db,"broadcastSources",activeId));
      updateActiveSourceUI(activeDoc.exists() ? {id:activeId, ...activeDoc.data()} : null);
    }else{
      updateActiveSourceUI(null);
    }
  }catch(error){
    console.error("loadBroadcastSources:", error);
    list.innerHTML = `
      <div class="source-item">
        <strong>تعذر تحميل المصادر</strong>
        <div class="source-help">تحقق من صلاحيات Firestore.</div>
      </div>`;
  }
}

function updateActiveSourceUI(source){
  const name = document.getElementById("activeSourceName");
  const type = document.getElementById("activeSourceType");
  const dot = document.getElementById("activeSourceDot");

  if(!name || !type || !dot) return;

  if(!source){
    name.textContent = "لا يوجد مصدر نشط";
    type.textContent = "متوقف";
    type.classList.remove("active");
    dot.classList.remove("active");
    return;
  }

  name.textContent = source.name || "مصدر";
  type.textContent = sourceTypeLabel(source.type);
  type.classList.add("active");
  dot.classList.add("active");
}


function ensureSourceSwitchStatus(){
  let el = document.getElementById("sourceSwitchStatus");
  if(el) return el;

  // Put the status immediately above the source control area if possible.
  const anchor = document.querySelector("#sourcesSection") ||
                 document.querySelector(".source-manager") ||
                 document.body;
  el = document.createElement("div");
  el.id = "sourceSwitchStatus";
  anchor.prepend(el);
  return el;
}

function showSourceSwitchStatus(type, message){
  const el = ensureSourceSwitchStatus();
  el.className = "sourceSwitchStatus " + type;
  el.style.display = "block";
  el.textContent = message;
}

async function waitForSourceSwitch(expectedName){
  const deadline = Date.now() + (3 * 60 * 1000);

  while(Date.now() < deadline){
    try{
      const response = await fetch(STREAM_ENGINE_URL + "/api/status?ts=" + Date.now(), {
        cache:"no-store"
      });

      if(response.ok){
        const state = await response.json();

        if(state.status === "switched" &&
           (!expectedName || state.source_name === expectedName)){
          showSourceSwitchStatus(
            "success",
            "🟢 نجحت العملية — تم تبديل البث إلى: " +
            (state.source_name || expectedName || "المصدر الجديد")
          );
          return true;
        }

        if(state.status === "running" && state.switch_failed){
          showSourceSwitchStatus(
            "error",
            "🔴 فشلت العملية — المصدر الجديد لم يعمل. البث الحالي مستمر."
          );
          return false;
        }

        if(state.status === "switching"){
          showSourceSwitchStatus(
            "pending",
            "🟡 جاري تحضير المصدر الجديد... لا تضغط تشغيل مرة أخرى."
          );
        }
      }
    }catch(error){
      console.warn("status check:", error);
    }

    await new Promise(resolve => setTimeout(resolve, 5000));
  }

  showSourceSwitchStatus(
    "error",
    "🔴 لم يصل تأكيد خلال 3 دقائق. لا نعيد التجربة الآن؛ افحص Railway Logs."
  );
  return false;
}

window.startHichrawiSource = async(id)=>{
  try{
    const sourceRef = doc(db,"broadcastSources",id);
    const snap = await getDoc(sourceRef);

    if(!snap.exists()){
      alert("❌ المصدر غير موجود");
      return;
    }

    const source = snap.data();
    let items = [];

    // Resolve a video playlist into concrete server/local URLs.
    if(source.type === "videos"){
      if(!source.libraryId){
        alert("❌ لم يتم تحديد قائمة تشغيل للفيديوهات");
        return;
      }

      const pSnap = await getDoc(doc(db,"playlists",source.libraryId));
      if(!pSnap.exists()){
        alert("❌ قائمة التشغيل غير موجودة");
        return;
      }

      const ids = Array.isArray(pSnap.data().videoIds) ? pSnap.data().videoIds : [];
      for(const videoId of ids){
        const vSnap = await getDoc(doc(db,"videos",videoId));
        if(!vSnap.exists()) continue;
        const v = vSnap.data();

        // Prefer serverPath for videos already stored on Railway.
        if(v.serverPath){
          items.push("/videos/" + encodeURIComponent(v.serverPath).replace(/%2F/g,"/"));
        }else if(v.url){
          items.push(v.url);
        }
      }

      if(!items.length){
        alert("❌ قائمة التشغيل فارغة");
        return;
      }
    }

    const user = auth.currentUser;
    if(!user){
      alert("❌ انتهت جلسة الإدارة. سجل الدخول من جديد.");
      return;
    }

    const idToken = await user.getIdToken();

    const request = {
      type: source.type || "iptv",
      name: source.name || "",
      url: source.type === "videos" ? "" : (source.url || ""),
      items,
      requestedAt: Date.now()
    };

    showSourceSwitchStatus(
      "pending",
      "🟡 تم إرسال المصدر الجديد... جاري تحضيره قبل تبديل البث."
    );

    const response = await fetch(STREAM_ENGINE_URL + "/api/source",{
      method:"POST",
      headers:{
        "Content-Type":"application/json",
        "Authorization":"Bearer " + idToken,
        "X-Firebase-Api-Key": firebaseConfig.apiKey
      },
      body:JSON.stringify(request)
    });

    if(!response.ok){
      const text=await response.text();
      throw new Error(text || ("HTTP "+response.status));
    }

    // Mark the requested source in Firestore without changing the old URL blindly.
    const all = await getDocs(collection(db,"broadcastSources"));
    await Promise.all(all.docs.map(item =>
      updateDoc(doc(db,"broadcastSources",item.id),{
        enabled:item.id===id,
        active:item.id===id,
        updatedAt:new Date()
      })
    ));

    await setDoc(doc(db,"settings","stream"),{
      activeSourceId:id,
      activeSourceName:source.name||"",
      activeSourceType:source.type||"iptv",
      requestedSource:source.type==="videos" ? (source.libraryId||"") : (source.url||""),
      activeLibraryId:source.libraryId||"",
      sourceStatus:"pending",
      sourceRequestedAt:new Date()
    },{merge:true});

    await loadBroadcastSources();

    // Do not rely on the Firestore "active" badge.
    // Poll the real engine state until it reports switched/failed.
    waitForSourceSwitch(source.name || "");
  }catch(error){
    console.error("startHichrawiSource:",error);
    alert("❌ تعذر إرسال المصدر إلى محرك البث.\n"+(error.message||""));
  }
};

window.stopHichrawiSource = async(id)=>{
  try{
    const user = auth.currentUser;
    if(!user){
      alert("❌ سجل الدخول من جديد.");
      return;
    }

    const idToken = await user.getIdToken();
    const response = await fetch(STREAM_ENGINE_URL + "/api/source",{
      method:"POST",
      headers:{
        "Content-Type":"application/json",
        "Authorization":"Bearer " + idToken,
        "X-Firebase-Api-Key": firebaseConfig.apiKey
      },
      body:JSON.stringify({
        type:"stop",
        name:"إيقاف البث",
        requestedAt:Date.now()
      })
    });

    if(!response.ok) throw new Error("HTTP "+response.status);

    await setDoc(doc(db,"settings","stream"),{
      sourceStatus:"stopped",
      stoppedSourceId:id||"",
      stoppedAt:new Date()
    },{merge:true});

    await loadBroadcastSources();
    alert("⏹️ تم إرسال أمر الإيقاف.");
  }catch(error){
    console.error("stopHichrawiSource:",error);
    alert("❌ تعذر إيقاف المصدر.\n"+(error.message||""));
  }
};


async function postFallbackSource(source){
  const user = auth.currentUser;
  if(!user) throw new Error("انتهت جلسة الإدارة");
  const idToken = await user.getIdToken();
  const response = await fetch(STREAM_ENGINE_URL + "/api/fallback", {
    method:"POST",
    headers:{
      "Content-Type":"application/json",
      "Authorization":"Bearer " + idToken,
      "X-Firebase-Api-Key": firebaseConfig.apiKey
    },
    body:JSON.stringify({
      sourceId: source.id || "",
      name: source.name || "",
      type: source.type || "iptv",
      url: source.url || "",
      items: source.items || [],
      libraryId: source.libraryId || "",
      enabled:true,
      updatedAt: Date.now()
    })
  });
  if(!response.ok){
    const t=await response.text();
    throw new Error(t || ("HTTP "+response.status));
  }
  return response.json();
}

window.setHichrawiFallback = async(id)=>{
  try{
    const source = await getSourceDefinitionForSchedule(id);
    showSourceSwitchStatus("pending","🟡 جاري حفظ المصدر الرئيسي الاحتياطي...");
    await postFallbackSource(source);
    showSourceSwitchStatus("success","🟢 تم تعيين «"+source.name+"» كمصدر رئيسي احتياطي. إذا تعطل أي مصدر آخر، Railway يرجع له تلقائياً.");
    await loadBroadcastSources();
  }catch(e){
    console.error("setHichrawiFallback:",e);
    showSourceSwitchStatus("error","🔴 تعذر تعيين المصدر الاحتياطي: "+(e.message||e));
  }
};

window.clearHichrawiFallback = async()=>{
  try{
    const user=auth.currentUser;
    if(!user) throw new Error("انتهت جلسة الإدارة");
    const idToken=await user.getIdToken();
    const r=await fetch(STREAM_ENGINE_URL+"/api/fallback",{
      method:"POST",
      headers:{
        "Content-Type":"application/json",
        "Authorization":"Bearer "+idToken,
        "X-Firebase-Api-Key":firebaseConfig.apiKey
      },
      body:JSON.stringify({enabled:false})
    });
    if(!r.ok) throw new Error(await r.text());
    const label=document.getElementById("fallbackSourceName");
    if(label) label.textContent="غير محدد";
    const select=document.getElementById("fallbackSourceSelect");
    if(select) select.value="";
    showSourceSwitchStatus("success","🟢 تم إلغاء المصدر الرئيسي الاحتياطي.");
    await loadBroadcastSources();
  }catch(e){
    showSourceSwitchStatus("error","🔴 تعذر إلغاء المصدر الاحتياطي: "+(e.message||e));
  }
};

window.deleteHichrawiSource = async(id)=>{
  if(!confirm("حذف مصدر البث؟")) return;

  try{
    const streamRef = doc(db,"settings","stream");
    const streamSnap = await getDoc(streamRef);
    const stream = streamSnap.exists() ? streamSnap.data() : {};

    if(stream.activeSourceId === id){
      await setDoc(streamRef,{
        ...stream,
        activeSourceId:"",
        activeSourceName:"",
        activeSourceType:"",
        sourceStatus:"stopped",
        stoppedAt:new Date()
      },{merge:true});
    }

    await deleteDoc(doc(db,"broadcastSources",id));
    await loadBroadcastSources();
  }catch(error){
    console.error("deleteHichrawiSource:", error);
    alert("❌ تعذر حذف المصدر");
  }
};

// ================= STREAM SOURCE MANAGEMENT =================

// حفظ مصدر IPTV الجديد
// يحفظ الطلب في Firebase فقط؛ لا يوقف FFmpeg ولا يلمس البث الحالي.
window.saveStream=async()=>{
 const input = document.getElementById("streamUrl");
 const url = input?.value.trim() || "";

 if(!url){
  alert("❌ أدخل رابط IPTV أولاً");
  return;
 }

 if(!/^https?:\/\//i.test(url)){
  alert("❌ الرابط يجب أن يبدأ بـ http:// أو https://");
  return;
 }

 try{
  const streamRef = doc(db,"settings","stream");
  const snap = await getDoc(streamRef);
  const current = snap.exists() ? snap.data() : {};

  await setDoc(streamRef,{
   ...current,
   url,
   requestedSource:url,
   sourceStatus:"pending",
   sourceRequestedAt:new Date()
  },{merge:true});

  alert("✅ تم حفظ مصدر IPTV الجديد\n\nالبث الحالي يبقى كما هو إلى أن يصبح المصدر الجديد جاهزاً.");
 }catch(e){
  console.error("saveStream:",e);
  alert("❌ تعذر حفظ مصدر البث");
 }
};

// حفظ معلومات الاتصال
window.saveContact=async()=>{
 await setDoc(doc(db,"contact","info"),{
  phone:document.getElementById("phone")?.value||"",
  whatsapp:document.getElementById("whatsapp")?.value||"",
  address:document.getElementById("address")?.value||"",
  email:document.getElementById("email")?.value||"",
  adminEmail:document.getElementById("adminEmail")?.value||"",
  facebook:document.getElementById("facebook")?.value||"",
  instagram:document.getElementById("instagram")?.value||"",
  tiktok:document.getElementById("tiktok")?.value||"",
  youtube:document.getElementById("youtube")?.value||"",
  telegram:document.getElementById("telegram")?.value||""
 });
 alert("تم حفظ معلومات الاتصال");
};


// ================= CHANNEL SETTINGS =================
window.loadSettings=async()=>{
 try{
  const snap=await getDoc(doc(db,"settings","general"));
  if(!snap.exists()) return;
  const d=snap.data()||{};
  const name=document.getElementById("channelName");
  const description=document.getElementById("channelDescription");
  if(name) name.value=d.name||"";
  if(description) description.value=d.description||"";
 }catch(e){
  console.error("loadSettings:",e);
 }
};

window.saveSettings=async()=>{
 try{
  await setDoc(doc(db,"settings","general"),{
   name:document.getElementById("channelName")?.value.trim() || "",
   description:document.getElementById("channelDescription")?.value.trim() || "",
   updatedAt:new Date()
  },{merge:true});
  const msg=document.getElementById("settingsMessage");
  if(msg) msg.textContent="✅ تم حفظ الإعدادات";
  else alert("تم حفظ إعدادات القناة");
 }catch(e){
  console.error("saveSettings:",e);
  alert("❌ تعذر حفظ إعدادات القناة: "+(e.message||e));
 }
};
// ================= VIDEO LIBRARY + PLAYLISTS =================

function setVideoManagerMessage(message, error=false){
    const el = document.getElementById("videoManagerMessage");
    if(!el) return;
    el.textContent = message;
    el.style.color = error ? "#ff7675" : "#aaa";
}

window.openAddVideo = () => {
    const m = document.getElementById("videoModal");
    if(m) m.style.display = "flex";
};

window.closeVideo = () => {
    const m = document.getElementById("videoModal");
    if(m) m.style.display = "none";
};

window.uploadVideoFile = async () => {
    const fileInput = document.getElementById("videoFile");
    const titleInput = document.getElementById("videoTitle");
    const file = fileInput?.files?.[0];

    if(!file){
        setVideoManagerMessage("اختر فيديو أولاً.", true);
        return;
    }

    const title = (titleInput?.value || file.name.replace(/\.[^.]+$/, "")).trim();
    if(!title){
        setVideoManagerMessage("اكتب اسم الفيديو.", true);
        return;
    }

    try{
        setVideoManagerMessage("⏳ جاري رفع الفيديو...");
        const safeName = file.name.replace(/[^\w\u0600-\u06FF.\- ]/g, "_");
        const storageRef = ref(storage, `hichrawi-videos/${Date.now()}_${safeName}`);

        await uploadBytes(storageRef, file, {
            contentType: file.type || "video/mp4"
        });

        const url = await getDownloadURL(storageRef);

        await addDoc(collection(db, "videos"), {
            title,
            url,
            storagePath: storageRef.fullPath,
            size: file.size,
            contentType: file.type || "",
            createdAt: new Date()
        });

        fileInput.value = "";
        if(titleInput) titleInput.value = "";

        setVideoManagerMessage("✅ تم رفع الفيديو وإضافته للمكتبة.");
        await loadVideos();
        await loadPlaylists();
    }catch(error){
        console.error("uploadVideoFile:", error);
        setVideoManagerMessage("❌ فشل الرفع. تأكد من تفعيل Firebase Storage وقواعده.", true);
    }
};

window.saveVideo = async () => {
    const title = (document.getElementById("videoTitle")?.value || "").trim();
    const url = (document.getElementById("videoUrl")?.value || "").trim();

    if(!title || !url){
        setVideoManagerMessage("أدخل عنوان الفيديو والرابط.", true);
        return;
    }

    if(!/^https?:\/\//i.test(url)){
        setVideoManagerMessage("الرابط يجب أن يبدأ بـ http:// أو https://", true);
        return;
    }

    try{
        await addDoc(collection(db,"videos"),{
            title,
            url,
            storagePath:"",
            createdAt:new Date()
        });

        document.getElementById("videoTitle").value = "";
        document.getElementById("videoUrl").value = "";

        setVideoManagerMessage("✅ تمت إضافة الفيديو بالرابط.");
        await loadVideos();
        await loadPlaylists();
    }catch(error){
        console.error("saveVideo:", error);
        setVideoManagerMessage("❌ تعذر حفظ الفيديو.", true);
    }
};

async function loadVideos(){
    const list = document.getElementById("videoLibraryList");
    const videoSelect = document.getElementById("playlistVideoSelect");
    if(!list) return;

    try{
        const snap = await getDocs(collection(db,"videos"));

        if(snap.empty){
            list.innerHTML = '<div class="library-empty">لا توجد فيديوهات</div>';
            if(videoSelect) videoSelect.innerHTML = '<option value="">لا توجد فيديوهات</option>';
            return;
        }

        list.innerHTML = "";
        if(videoSelect) videoSelect.innerHTML = "";

        snap.forEach(item=>{
            const d = item.data();
            const title = String(d.title || "فيديو").replace(/</g,"&lt;").replace(/>/g,"&gt;");
            const url = String(d.url || "").replace(/</g,"&lt;").replace(/>/g,"&gt;");

            list.innerHTML += `
              <div class="video-row">
                <span>🎬</span>
                <div>
                  <div class="video-row-title">${title}</div>
                  <div class="video-row-url">${url}</div>
                </div>
                <button class="btn delete" onclick="deleteVideo('${item.id}')">🗑️</button>
              </div>`;

            if(videoSelect){
                const option = document.createElement("option");
                option.value = item.id;
                option.textContent = d.title || "فيديو";
                videoSelect.appendChild(option);
            }
        });
    }catch(error){
        console.error("loadVideos:", error);
        list.innerHTML = '<div class="library-empty">تعذر تحميل الفيديوهات</div>';
    }
}

window.deleteVideo = async(id)=>{
    if(!confirm("حذف الفيديو؟")) return;

    try{
        const videoRef = doc(db,"videos",id);
        const snap = await getDoc(videoRef);

        if(snap.exists()){
            const d = snap.data();
            if(d.storagePath){
                try{
                    await deleteObject(ref(storage, d.storagePath));
                }catch(storageError){
                    console.warn("Storage delete:", storageError);
                }
            }
        }

        await deleteDoc(videoRef);
        await loadVideos();
        await loadPlaylists();
        setVideoManagerMessage("🗑️ تم حذف الفيديو.");
    }catch(error){
        console.error("deleteVideo:", error);
        setVideoManagerMessage("❌ تعذر حذف الفيديو.", true);
    }
};

// ================= SERVER VIDEO LIBRARY =================
// Reads the server-side video library through the future /api/videos endpoint.
// No Railway/FFmpeg changes are made by admin.js in this stage.

let serverVideosCache = [];

window.loadServerVideos = async()=>{
    const list = document.getElementById("serverVideoList");
    const status = document.getElementById("serverVideoStatus");
    if(!list) return;

    list.innerHTML = '<div class="library-empty">⏳ جاري قراءة مكتبة السيرفر...</div>';
    if(status) status.textContent = "الاتصال بـ /api/videos ...";

    try{
        const response = await fetch(STREAM_ENGINE_URL + "/api/videos", {
            method:"GET",
            headers:{ "Accept":"application/json" },
            cache:"no-store"
        });

        if(!response.ok){
            throw new Error("HTTP " + response.status);
        }

        const data = await response.json();
        serverVideosCache = Array.isArray(data) ? data :
                            (Array.isArray(data.videos) ? data.videos : []);

        renderServerVideos();

        if(status){
            status.textContent = serverVideosCache.length
                ? `✅ تم العثور على ${serverVideosCache.length} فيديو في السيرفر.`
                : "المجلد موجود لكن لا توجد فيديوهات.";
        }
    }catch(error){
        console.error("loadServerVideos:", error);
        serverVideosCache = [];
        list.innerHTML = `
          <div class="library-empty">
            ⚠️ واجهة السيرفر /api/videos غير مربوطة بعد.
            <br>لن نغيّر البث الحالي. سيتم ربطها في مرحلة محرك البث.
          </div>`;
        if(status) status.textContent = "لم يتم الاتصال بمكتبة السيرفر.";
    }
};

function renderServerVideos(){
    const list=document.getElementById("serverVideoList");
    if(!list) return;

    const q=(document.getElementById("serverVideoSearch")?.value || "").trim().toLowerCase();
    const filtered=serverVideosCache.filter(v=>{
        const name=String(v.name || v.title || v.filename || "").toLowerCase();
        return !q || name.includes(q);
    });

    if(!filtered.length){
        list.innerHTML='<div class="library-empty">لا توجد نتائج.</div>';
        return;
    }

    list.innerHTML="";
    filtered.forEach((v,index)=>{
        const name=String(v.name || v.title || v.filename || "فيديو");
        const path=String(v.path || v.url || v.filename || "");
        const safeName=name.replace(/</g,"&lt;").replace(/>/g,"&gt;");
        const safePath=path.replace(/</g,"&lt;").replace(/>/g,"&gt;");

        list.innerHTML += `
          <div class="video-row">
            <span>📁</span>
            <div>
              <div class="video-row-title">${safeName}</div>
              <div class="video-row-url">${safePath}</div>
            </div>
            <button class="btn add" onclick="addServerVideoToLibrary(${index})">
              ➕ إضافة
            </button>
          </div>`;
    });
}

window.filterServerVideos=()=>renderServerVideos();

window.addServerVideoToLibrary=async(index)=>{
    const v=serverVideosCache[index];
    if(!v){
        setVideoManagerMessage("الفيديو غير موجود في قائمة السيرفر.", true);
        return;
    }

    const name=String(v.name || v.title || v.filename || "فيديو");
    const serverPath=String(v.path || v.url || v.filename || "");

    if(!serverPath){
        setVideoManagerMessage("مسار الفيديو غير موجود.", true);
        return;
    }

    try{
        // Avoid duplicates by serverPath.
        const snap=await getDocs(collection(db,"videos"));
        let exists=false;
        snap.forEach(item=>{
            if(item.data().serverPath === serverPath) exists=true;
        });

        if(exists){
            setVideoManagerMessage("الفيديو موجود بالفعل في المكتبة.");
            return;
        }

        await addDoc(collection(db,"videos"),{
            title:name,
            url:serverPath.startsWith("http") ? serverPath : `/videos/${encodeURIComponent(serverPath.split("/").pop())}`,
            serverPath,
            sourceType:"server",
            storagePath:"",
            createdAt:new Date()
        });

        await loadVideos();
        await loadPlaylists();
        setVideoManagerMessage("✅ تمت إضافة فيديو السيرفر إلى المكتبة.");
    }catch(error){
        console.error("addServerVideoToLibrary:",error);
        setVideoManagerMessage("❌ تعذر إضافة فيديو السيرفر.",true);
    }
};

// ================= PLAYLIST MANAGEMENT =================

window.createPlaylist = async()=>{
    const input = document.getElementById("playlistName");
    const name = (input?.value || "").trim();

    if(!name){
        setVideoManagerMessage("اكتب اسم قائمة التشغيل.", true);
        return;
    }

    try{
        await addDoc(collection(db,"playlists"),{
            name,
            videoIds:[],
            createdAt:new Date(),
            updatedAt:new Date()
        });

        input.value = "";
        await loadPlaylists();
        setVideoManagerMessage("✅ تم إنشاء قائمة التشغيل.");
    }catch(error){
        console.error("createPlaylist:", error);
        setVideoManagerMessage("❌ تعذر إنشاء القائمة.", true);
    }
};

async function loadPlaylists(){
    const list = document.getElementById("playlistList");
    const playlistSelect = document.getElementById("playlistSelect");
    const sourceSelect = document.getElementById("videosLibrary");

    if(!list) return;

    try{
        const snap = await getDocs(collection(db,"playlists"));

        if(playlistSelect) playlistSelect.innerHTML = "";
        if(sourceSelect) sourceSelect.innerHTML = "";

        if(snap.empty){
            list.innerHTML = '<div class="library-empty">لا توجد قوائم</div>';
            if(playlistSelect) playlistSelect.innerHTML = '<option value="">لا توجد قوائم</option>';
            if(sourceSelect) sourceSelect.innerHTML = '<option value="">🎬 أنشئ قائمة أولاً</option>';
            return;
        }

        list.innerHTML = "";

        for(const item of snap.docs){
            const d = item.data();
            const ids = Array.isArray(d.videoIds) ? d.videoIds : [];

            if(playlistSelect){
                const option = document.createElement("option");
                option.value = item.id;
                option.textContent = d.name || "قائمة";
                playlistSelect.appendChild(option);
            }

            if(sourceSelect){
                const option = document.createElement("option");
                option.value = item.id;
                option.textContent = "🎬 " + (d.name || "قائمة");
                sourceSelect.appendChild(option);
            }

            let titles = [];
            for(const id of ids){
                try{
                    const vSnap = await getDoc(doc(db,"videos",id));
                    if(vSnap.exists()) titles.push(vSnap.data().title || "فيديو");
                }catch(_){}
            }

            const safeName = String(d.name || "قائمة").replace(/</g,"&lt;").replace(/>/g,"&gt;");

            list.innerHTML += `
              <div class="playlist-row" data-playlist-id="${item.id}">
                <div class="playlist-head">
                  <strong>📋 ${safeName}</strong>
                  <span class="source-badge">${ids.length} فيديو</span>
                </div>
                <div class="playlist-videos">
                  ${titles.length ? titles.map((t,i)=>(i+1)+". "+String(t).replace(/</g,"&lt;")).join("<br>") : "القائمة فارغة"}
                </div>
                <div class="small-actions">
                  <button class="btn add" onclick="selectPlaylistAsSource('${item.id}')">📡 جعلها مصدر البث</button>
                  <button class="btn delete" onclick="deletePlaylist('${item.id}')">🗑️ حذف القائمة</button>
                </div>
              </div>`;
        }
    }catch(error){
        console.error("loadPlaylists:", error);
        list.innerHTML = '<div class="library-empty">تعذر تحميل القوائم</div>';
    }
}

window.addVideoToPlaylist = async()=>{
    const playlistId = document.getElementById("playlistSelect")?.value;
    const videoId = document.getElementById("playlistVideoSelect")?.value;

    if(!playlistId || !videoId){
        setVideoManagerMessage("اختر قائمة وفيديو أولاً.", true);
        return;
    }

    try{
        const playlistRef = doc(db,"playlists",playlistId);
        const snap = await getDoc(playlistRef);

        if(!snap.exists()){
            setVideoManagerMessage("القائمة غير موجودة.", true);
            return;
        }

        const d = snap.data();
        const ids = Array.isArray(d.videoIds) ? [...d.videoIds] : [];

        if(!ids.includes(videoId)) ids.push(videoId);

        await updateDoc(playlistRef,{videoIds:ids,updatedAt:new Date()});
        await loadPlaylists();
        setVideoManagerMessage("✅ تمت إضافة الفيديو إلى القائمة.");
    }catch(error){
        console.error("addVideoToPlaylist:", error);
        setVideoManagerMessage("❌ تعذر تعديل القائمة.", true);
    }
};

window.selectPlaylistAsSource = async(playlistId)=>{
    const sourceSelect = document.getElementById("videosLibrary");
    if(sourceSelect) sourceSelect.value = playlistId;

    const typeSelect = document.getElementById("sourceType");
    if(typeSelect){
        typeSelect.value = "videos";
        if(typeof updateSourceForm === "function") updateSourceForm();
    }

    const playlist = await getDoc(doc(db,"playlists",playlistId));
    if(playlist.exists()){
        const nameInput = document.getElementById("sourceName");
        if(nameInput) nameInput.value = playlist.data().name || "فيديوهاتي";
    }

    document.getElementById("sourcesSection")?.scrollIntoView({behavior:"smooth"});
    setVideoManagerMessage("تم اختيار القائمة كمصدر. احفظ المصدر من قسم 🎛️ مصادر البث.");
};

window.deletePlaylist = async(id)=>{
    if(!confirm("حذف قائمة التشغيل؟ الفيديوهات نفسها لن تُحذف.")) return;

    try{
        await deleteDoc(doc(db,"playlists",id));
        await loadPlaylists();
        setVideoManagerMessage("🗑️ تم حذف قائمة التشغيل.");
    }catch(error){
        console.error("deletePlaylist:", error);
        setVideoManagerMessage("❌ تعذر حذف القائمة.", true);
    }
};

// ================= STREAM LOGO MANAGEMENT =================


async function applyLogoUrlToEngine(url){
  const clean = String(url||"").trim();
  if(!clean) return;
  const user=auth.currentUser;
  if(!user) throw new Error("انتهت جلسة الإدارة");
  const idToken=await user.getIdToken();
  const r=await fetch(STREAM_ENGINE_URL+"/api/logo",{
    method:"POST",
    headers:{
      "Content-Type":"application/json",
      "Authorization":"Bearer "+idToken,
      "X-Firebase-Api-Key":firebaseConfig.apiKey
    },
    body:JSON.stringify({url:clean})
  });
  if(!r.ok){
    const t=await r.text();
    throw new Error(t||("HTTP "+r.status));
  }
  return r.json();
}

window.uploadStreamLogo = async()=>{
  try{
    const file=document.getElementById("streamLogoFile")?.files?.[0];
    if(!file){ alert("اختر صورة الشعار أولاً"); return; }
    if(!/^image\//i.test(file.type)){ alert("الملف يجب أن يكون صورة"); return; }
    if(file.size > 5*1024*1024){ alert("حجم الشعار يجب ألا يتجاوز 5MB"); return; }

    const safeName = file.name.replace(/[^a-zA-Z0-9._-]/g,"_");
    const path = `stream-logo/${Date.now()}-${safeName}`;
    const storageRef = ref(storage, path);
    await uploadBytes(storageRef,file,{contentType:file.type});
    const url = await getDownloadURL(storageRef);

    await setDoc(doc(db,"settings","stream"),{logo:url,logoUpdatedAt:new Date()},{merge:true});
    await applyLogoUrlToEngine(url);

    const input=document.getElementById("streamLogo");
    const preview=document.getElementById("streamLogoPreview");
    if(input) input.value=url;
    if(preview) preview.src=url;
    alert("🟢 تم رفع الشعار وحفظه وتطبيقه على البث.");
  }catch(e){
    console.error("uploadStreamLogo:",e);
    alert("🔴 تعذر رفع/تطبيق الشعار.\n"+(e.message||e));
  }
};

// حفظ شعار البث
window.saveStreamLogo = async()=>{

 const logo = document.getElementById("streamLogo")?.value || "";

 await setDoc(doc(db,"settings","stream"),{
    logo: logo
 },{merge:true});

 if(logo){
   await applyLogoUrlToEngine(logo);
 }

 alert("تم حفظ شعار البث وتطبيقه على البث.");

 const preview=document.getElementById("streamLogoPreview");
 if(preview && logo){
    preview.src=logo;
 }

};


// حذف شعار البث
window.removeStreamLogo = async()=>{

 await setDoc(doc(db,"settings","stream"),{
    logo:""
 },{merge:true});

 const preview=document.getElementById("streamLogoPreview");
 if(preview){
    preview.src="";
 }

 const input=document.getElementById("streamLogo");
 if(input){
    input.value="";
 }

 alert("تم حذف الشعار");

};


// تحميل إعدادات البث (المصدر + الشعار)
async function loadStreamSettings(){

 const snap = await getDoc(doc(db,"settings","stream"));

 if(!snap.exists()) return;

 const data = snap.data();

 const streamInput = document.getElementById("streamUrl");
 if(streamInput) streamInput.value = data.url || "";

 const logoInput = document.getElementById("streamLogo");
 const preview = document.getElementById("streamLogoPreview");

 if(logoInput) logoInput.value = data.logo || "";

 if(preview) preview.src = data.logo || "";
}

// توافق مع أي كود قديم يستدعي هذه الدالة
async function loadStreamLogo(){
 await loadStreamSettings();
}



// ================= VIEWER ANALYTICS =================
async function refreshViewerStats(){
  try{
    const r = await fetch(STREAM_ENGINE_URL + "/api/viewers?ts=" + Date.now(), {cache:"no-store"});
    if(!r.ok) throw new Error("HTTP " + r.status);
    const d = await r.json();
    const live = document.getElementById("liveViewers");
    const today = document.getElementById("todayViews");
    const total = document.getElementById("totalViews");
    if(live) live.textContent = Number(d.live_viewers || 0).toLocaleString("ar-TN");
    if(today) today.textContent = Number(d.today_views || 0).toLocaleString("ar-TN");
    if(total) total.textContent = Number(d.total_views || 0).toLocaleString("ar-TN");
  }catch(e){
    console.warn("viewer stats", e);
  }
}
window.refreshViewerStats = refreshViewerStats;

// ================= LIVE BROADCAST DASHBOARD =================
function formatDashTime(value){
  if(!value) return "—";
  const d = new Date(typeof value === "number" ? value : value);
  if(Number.isNaN(d.getTime())) return "—";
  return d.toLocaleString("ar-TN", {
    day:"2-digit", month:"2-digit", year:"numeric",
    hour:"2-digit", minute:"2-digit", second:"2-digit"
  });
}

function dashSet(id, value, cls=""){
  const el = document.getElementById(id);
  if(!el) return;
  el.textContent = value;
  el.className = "stat-value " + cls;
}

async function refreshLiveDashboard(){
  const statusEl = document.getElementById("liveDashboardStatus");
  if(statusEl) statusEl.textContent = "🟡 جاري قراءة حالة البث...";

  try{
    const r = await fetch(STREAM_ENGINE_URL + "/api/status?ts=" + Date.now(), {
      cache:"no-store"
    });
    if(!r.ok) throw new Error("HTTP " + r.status);

    const s = await r.json();
    const state = String(s.status || "unknown");

    let label = "⚪ غير معروف";
    let cls = "warn";

    if(state === "running"){
      label = s.switch_failed
        ? "🟠 يعمل — آخر تبديل فشل، والمصدر الحالي مستمر"
        : "🟢 يعمل";
      cls = s.switch_failed ? "warn" : "ok";
    }else if(state === "switching"){
      label = "🟡 جاري تحضير مصدر جديد";
    }else if(state === "switched"){
      label = "🟢 تم التبديل بنجاح";
      cls = "ok";
    }else if(state === "error" || state === "failed"){
      label = "🔴 خطأ";
      cls = "bad";
    }

    if(statusEl){
      statusEl.textContent = label + (s.message ? " — " + s.message : "");
      statusEl.className = cls;
    }

    dashSet("dashSource", s.source_name || "—");
    dashSet("dashType", s.source_type || "—");
    dashSet("dashEngine", label, cls);
    dashSet("dashSwitched", formatDashTime(s.switched_at || s.requested_at));
  }catch(err){
    console.error("refreshLiveDashboard:", err);
    if(statusEl){
      statusEl.textContent = "🔴 تعذر الاتصال بمحرك البث";
      statusEl.className = "bad";
    }
    dashSet("dashSource", "—");
    dashSet("dashType", "—");
    dashSet("dashEngine", "غير متصل", "bad");
    dashSet("dashSwitched", "—");
  }
}

window.refreshLiveDashboard = refreshLiveDashboard;

document.addEventListener("DOMContentLoaded", ()=>{
  refreshLiveDashboard();
  // Lightweight polling; does not restart or alter the stream.
  setInterval(refreshLiveDashboard, 10000);
});


// ================= BROADCAST SCHEDULE UI + RAILWAY =================
const HICHRAWI_SCHEDULE_KEY = "hichrawi_tv_broadcast_schedule_v2";
function getLocalSchedule(){try{return JSON.parse(localStorage.getItem(HICHRAWI_SCHEDULE_KEY)||"[]")}catch(e){return[]}}
function saveLocalSchedule(items){localStorage.setItem(HICHRAWI_SCHEDULE_KEY,JSON.stringify(items))}

async function scheduleAuthHeaders(){
  const user=auth.currentUser;
  if(!user) throw new Error("جلسة الإدارة منتهية");
  const idToken=await user.getIdToken();
  return {"Content-Type":"application/json","Authorization":"Bearer "+idToken,"X-Firebase-Api-Key":firebaseConfig.apiKey};
}

function browserTimezoneOffsetMinutes(){
  // Date#getTimezoneOffset is UTC-local. Negating it gives local-UTC minutes.
  return -new Date().getTimezoneOffset();
}

async function fetchServerSchedule(){
  const r=await fetch(STREAM_ENGINE_URL+"/api/schedule?ts="+Date.now(),{cache:"no-store"});
  if(!r.ok) throw new Error("HTTP "+r.status);
  const data=await r.json();
  const items=Array.isArray(data.items)?data.items:[];
  // Keep a UI-friendly copy locally, but the server copy is authoritative.
  saveLocalSchedule(items.map(x=>({
    time:x.time,name:x.name||x.source?.name||"مصدر",type:x.type||x.source?.type||"source",
    sourceId:x.sourceId||"",enabled:x.enabled!==false
  })));
  return data;
}

async function syncScheduleToRailway(items, enabled=true){
  const headers=await scheduleAuthHeaders();
  const payload={
    enabled,
    timezone_offset_minutes:browserTimezoneOffsetMinutes(),
    items
  };
  const r=await fetch(STREAM_ENGINE_URL+"/api/schedule",{
    method:"POST",headers,body:JSON.stringify(payload)
  });
  if(!r.ok){const t=await r.text();throw new Error(t||("HTTP "+r.status));}
  return r.json();
}

async function getSourceDefinitionForSchedule(id){
  const snap=await getDoc(doc(db,"broadcastSources",id));
  if(!snap.exists()) throw new Error("المصدر غير موجود");
  const source=snap.data();
  let items=[];
  if(source.type==="videos"){
    if(!source.libraryId) throw new Error("قائمة فيديوهات غير محددة للمصدر");
    const pSnap=await getDoc(doc(db,"playlists",source.libraryId));
    if(!pSnap.exists()) throw new Error("قائمة التشغيل غير موجودة");
    const ids=Array.isArray(pSnap.data().videoIds)?pSnap.data().videoIds:[];
    for(const videoId of ids){
      const vSnap=await getDoc(doc(db,"videos",videoId));
      if(!vSnap.exists()) continue;
      const v=vSnap.data();
      if(v.serverPath) items.push("/videos/"+encodeURIComponent(v.serverPath).replace(/%2F/g,"/"));
      else if(v.url) items.push(v.url);
    }
    if(!items.length) throw new Error("قائمة الفيديوهات فارغة");
  }
  return {
    id,
    name:source.name||"مصدر",
    type:source.type||"iptv",
    url:source.type==="videos"?"":(source.url||""),
    items,
    libraryId:source.libraryId||""
  };
}

async function loadScheduleSources(){
  const select=document.getElementById("scheduleSource"); if(!select)return;
  const previous=select.value;
  select.innerHTML='<option value="">اختر المصدر</option>';
  const snap=await getDocs(collection(db,"broadcastSources"));
  snap.forEach(item=>{
    const d=item.data();
    const o=document.createElement("option");
    o.value=item.id;
    o.textContent=(d.name||item.id)+" — "+(getHichrawiSourceTypeLabel(d.type)||d.type||"");
    select.appendChild(o);
  });
  if(previous)select.value=previous;
}

function renderBroadcastSchedule(items=getLocalSchedule()){
  const body=document.getElementById("scheduleTableBody"); if(!body)return;
  const sorted=[...items].sort((a,b)=>String(a.time).localeCompare(String(b.time)));
  if(!sorted.length){body.innerHTML='<tr><td colspan="5" class="schedule-empty">لا توجد برامج في الجدول بعد.</td></tr>';return}
  body.innerHTML="";
  sorted.forEach((item,index)=>{
    const tr=document.createElement("tr");
    tr.innerHTML=`<td>${item.time}</td><td>${item.name||item.source?.name||"مصدر"}</td><td>${item.type||item.source?.type||"source"}</td><td>${item.enabled!==false?"🟢 مفعّل":"⚪ متوقف"}</td><td><button class="btn delete" type="button" onclick="removeBroadcastSchedule(${index})">حذف</button></td>`;
    body.appendChild(tr);
  });
}

async function refreshBroadcastSchedule(){
  const msg=document.getElementById("scheduleMessage");
  try{
    const data=await fetchServerSchedule();
    renderBroadcastSchedule(data.items||[]);
    if(msg)msg.textContent=data.enabled?"🟢 الجدول مربوط بـRailway ويعمل من السيرفر حتى بعد إغلاق الحاسوب.":"⚪ الجدول محفوظ لكن التشغيل التلقائي متوقف.";
  }catch(e){
    console.warn("server schedule",e);
    renderBroadcastSchedule();
    if(msg)msg.textContent="⚠️ تعذر قراءة جدول Railway — المعروض محلياً فقط.";
  }
}

async function addBroadcastSchedule(){
  const time=document.getElementById("scheduleTime")?.value;
  const sel=document.getElementById("scheduleSource");
  const msg=document.getElementById("scheduleMessage");
  if(!time||!sel?.value){if(msg)msg.textContent="⚠️ اختر الوقت والمصدر أولاً.";return}
  try{
    if(msg)msg.textContent="🟡 جاري إرسال البرنامج إلى Railway...";
    const source=await getSourceDefinitionForSchedule(sel.value);
    const server=await fetchServerSchedule().catch(()=>({items:[]}));
    const items=Array.isArray(server.items)?server.items:[];
    // Replace an existing entry at the same time instead of creating duplicates.
    const clean=items.filter(x=>x.time!==time);
    clean.push({
      time,name:source.name,type:source.type,sourceId:source.id,enabled:true,source
    });
    await syncScheduleToRailway(clean,true);
    saveLocalSchedule(clean.map(x=>({time:x.time,name:x.name,type:x.type,sourceId:x.sourceId,enabled:x.enabled!==false})));
    renderBroadcastSchedule(clean);
    if(msg)msg.textContent="🟢 تمت إضافة البرنامج وربطه بـRailway. سيعمل حسب الوقت حتى لو الحاسوب مغلق.";
  }catch(e){
    console.error("addBroadcastSchedule",e);
    if(msg)msg.textContent="🔴 فشلت إضافة البرنامج: "+(e.message||e);
  }
}

async function removeBroadcastSchedule(index){
  try{
    const server=await fetchServerSchedule();
    const items=Array.isArray(server.items)?server.items:[];
    const sorted=[...items].sort((a,b)=>String(a.time).localeCompare(String(b.time)));
    sorted.splice(index,1);
    await syncScheduleToRailway(sorted,true);
    saveLocalSchedule(sorted.map(x=>({time:x.time,name:x.name,type:x.type,sourceId:x.sourceId,enabled:x.enabled!==false})));
    renderBroadcastSchedule(sorted);
  }catch(e){alert("❌ تعذر حذف البرنامج من Railway.\n"+(e.message||e))}
}

async function clearBroadcastSchedule(){
  if(!confirm("هل تريد مسح جدول البث من Railway؟"))return;
  try{
    await syncScheduleToRailway([],false);
    localStorage.removeItem(HICHRAWI_SCHEDULE_KEY);
    renderBroadcastSchedule([]);
    const msg=document.getElementById("scheduleMessage");
    if(msg)msg.textContent="🟢 تم مسح جدول البث من Railway.";
  }catch(e){alert("❌ تعذر مسح جدول Railway.\n"+(e.message||e))}
}
window.addBroadcastSchedule=addBroadcastSchedule;
window.removeBroadcastSchedule=removeBroadcastSchedule;
window.clearBroadcastSchedule=clearBroadcastSchedule;
window.refreshBroadcastSchedule=refreshBroadcastSchedule;

document.addEventListener("DOMContentLoaded",async()=>{
  await loadScheduleSources().catch(()=>{});
  await refreshBroadcastSchedule();
  setTimeout(loadScheduleSources,1500);
});


// ================= ANNOUNCEMENT / BREAKING NEWS =================
window.loadAnnouncement = async function(){
  try{
    const snap = await getDoc(doc(db,"settings","announcement"));
    const d = snap.exists() ? snap.data() : {};
    const ids = ["announcementText","announcementType","announcementSpeed","announcementBg","announcementColor","announcementSize"];
    const vals = [d.text||"", d.type||"breaking", String(d.speed||18), d.bgColor||"#e00000", d.textColor||"#ffffff", d.fontSize||"20px"];
    ids.forEach((id,i)=>{ const el=document.getElementById(id); if(el) el.value=vals[i]; });
    previewAnnouncement();
  }catch(e){ console.error("loadAnnouncement:",e); }
};

window.saveAnnouncement = async function(enabled){
  const data={
    text:document.getElementById("announcementText")?.value.trim()||"",
    type:document.getElementById("announcementType")?.value||"breaking",
    speed:Number(document.getElementById("announcementSpeed")?.value||18),
    bgColor:document.getElementById("announcementBg")?.value||"#e00000",
    textColor:document.getElementById("announcementColor")?.value||"#ffffff",
    fontSize:document.getElementById("announcementSize")?.value||"20px",
    enabled:Boolean(enabled),
    updatedAt:new Date()
  };
  if(enabled && !data.text){ alert("❌ اكتب نص الإعلان أولاً"); return; }
  try{
    await setDoc(doc(db,"settings","announcement"),data,{merge:true});
    const msg=document.getElementById("announcementMessage");
    if(msg) msg.textContent=enabled?"🟢 تم تشغيل الإعلان وحفظه.":"⏹️ تم إيقاف الإعلان وحفظ الإعدادات.";
    previewAnnouncement();
  }catch(e){ console.error("saveAnnouncement:",e); alert("❌ تعذر حفظ الإعلان: "+(e.message||e)); }
};

window.previewAnnouncement=function(){
  const track=document.getElementById("announcementPreviewTrack"), box=document.getElementById("announcementPreview");
  if(!track||!box)return;
  const labels={breaking:"🔴 عاجل",ad:"📢 إعلان",notice:"🟡 تنبيه",live:"🟢 مباشر"};
  const type=document.getElementById("announcementType")?.value||"breaking";
  const text=document.getElementById("announcementText")?.value.trim()||"HICHRAWI-TV";
  const bg=document.getElementById("announcementBg")?.value||"#e00000";
  const color=document.getElementById("announcementColor")?.value||"#ffffff";
  const size=document.getElementById("announcementSize")?.value||"20px";
  const speed=Number(document.getElementById("announcementSpeed")?.value||18);
  track.textContent=(labels[type]||"🔴 عاجل")+" : "+text;
  box.style.background=bg; track.style.color=color; track.style.fontSize=size; track.style.animationDuration=speed+"s";
};

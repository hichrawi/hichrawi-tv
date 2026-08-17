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
   loadBroadcastSources();
 }else{
  if(box) box.style.display="flex";
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
  if(type === "youtube") return "▶️ YouTube";
  if(type === "videos") return "🎬 فيديوهاتي";
  return "📡 IPTV";
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
    const activeId = streamData.activeSourceId || "";

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
      const isActive = item.id === activeId;
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
      url: (source.type === "iptv" || source.type === "youtube") ? (source.url || "") : "",
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


// حفظ إعدادات القناة
window.saveSettings=async()=>{
 await setDoc(doc(db,"settings","general"),{
  name:document.getElementById("channelName")?.value || "",
  description:document.getElementById("channelDescription")?.value || ""
 });
 alert("تم حفظ إعدادات القناة");
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

// حفظ شعار البث
window.saveStreamLogo = async()=>{

 const logo = document.getElementById("streamLogo")?.value || "";

 await setDoc(doc(db,"settings","stream"),{
    logo: logo
 },{merge:true});

 alert("تم حفظ شعار البث");

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

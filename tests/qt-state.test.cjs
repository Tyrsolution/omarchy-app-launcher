const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const os=require('node:os');
const {spawnSync}=require('node:child_process');
const {source,functionSource,dir}=require('./launcher-harness.cjs');
function run(t,body) {
 const tmp=fs.mkdtempSync(path.join(os.tmpdir(),'launcher-qt-test-'));
 t.after(()=>fs.rmSync(tmp,{recursive:true,force:true}));
 for(const file of ['SessionState.js','Favorites.js']) fs.copyFileSync(path.join(dir,file),path.join(tmp,file));
 const file=path.join(tmp,'fixture.qml');fs.writeFileSync(file,'import QtQuick\nimport "SessionState.js" as SessionState\nimport "Favorites.js" as Favorites\n'+body);
 const runtime=path.join(tmp,'runtime');fs.mkdirSync(runtime,{mode:0o700});
 const env={...process.env,QT_QPA_PLATFORM:'offscreen',QT_QPA_PLATFORMTHEME:'generic',QT_QUICK_CONTROLS_STYLE:'Basic',QT_FORCE_STDERR_LOGGING:'1',XDG_RUNTIME_DIR:runtime};
 delete env.WAYLAND_DISPLAY;
 const r=spawnSync('qs',['-p',file],{env,encoding:'utf8',timeout:8000,killSignal:'SIGKILL'});
 assert.ifError(r.error);assert.equal(r.status,0,r.stdout+r.stderr);
 assert.doesNotMatch(r.stdout+r.stderr,/binding loop|ReferenceError|TypeError|failed to load/i);
 return r.stdout+r.stderr;
}
// This fixture copies the actual session property and its change handler.
// The real launcher remains unloaded; only Qt's Loader lifecycle is used.
test('collapse survives overlay destruction but resets in a fresh shell engine',t=>{
 const property=source.match(/  property bool stripCollapsed: .+/)[0];
 const handler=source.match(/  onStripCollapsedChanged: .+/)[0];
 const body=`Item {
 id: host
 Loader { id: loader; sourceComponent: Component { Item { id: root
 ${property}
 ${handler}
 } } }
 function check(ok,message) { if(!ok) { console.error(message);Qt.exit(2);throw new Error(message) } }
 Timer { interval:30;running:true;onTriggered: {
  check(!loader.item.stripCollapsed,"initial state must be expanded")
  loader.item.stripCollapsed=true
  loader.active=false
  check(loader.item===null,"overlay must be destroyed")
  loader.active=true
  check(loader.item.stripCollapsed,"collapse must survive reopening")
  loader.item.stripCollapsed=false
  loader.active=false;loader.active=true
  check(!loader.item.stripCollapsed,"expansion must survive reopening")
  loader.item.stripCollapsed=true
  console.log("session state passed");Qt.quit()
 } }
 Timer { interval:5000;running:true;onTriggered:Qt.exit(9) }
}`;
 assert.match(run(t,body),/session state passed/);
 // Previous process ended collapsed; a fresh engine must still start expanded.
 assert.match(run(t,body),/session state passed/);
});
test('Qt saved-tab restore keeps keyboard selection on the visible content',t=>{
 const funcs=['restoreView','rowsFor','rowAt','selectedRow','select','resetSelection'].map(functionSource).join('\n');
 const body=`Item { id:root
 property string activeTab:"favorites"
 property bool interacted:false
 property bool viewInteracted:false
 property bool stripOpen:true
 property string selectedSection:"all"
 property int selectedIndex:0
 property var favoriteRows:[{id:"pin"}]
 property var frequentRows:[{id:"frequent"}]
 property var displayRows:[{id:"application"}]
 property var systemRows:[]
 ${funcs}
 Timer {interval:30;running:true;onTriggered: {
  root.resetSelection()
  root.restoreView('{"tab":"frequent"}')
  if(root.selectedRow().id!=="frequent") {Qt.exit(2);return}
  root.interacted=true;root.select("all",0)
  root.restoreView('{"tab":"favorites"}')
  if(root.selectedRow().id!=="application" || root.activeTab!=="frequent") {Qt.exit(3);return}
  Qt.quit()
 } }
 Timer {interval:5000;running:true;onTriggered:Qt.exit(9)}
}`;
 run(t,body);
});

const test=require('node:test');
const assert=require('node:assert/strict');
const vm=require('node:vm');
const {fresh,handler}=require('./launcher-harness.cjs');
const plain=v=>JSON.parse(JSON.stringify(v));
function pins(c,ids){c.favorites=ids;c.markAllSeen();return plain(c.favorites);}

test('missing host app library never erases app favorites or usage',()=>{
 const c=fresh();c.appLibrary=null;c.usage={saved:{score:2}};
 assert.deepEqual(pins(c,['saved']),['saved']);assert.equal(c.usage.saved.score,2);assert.equal(c.savedSeen,undefined);
});
test('empty app library during startup is not mass uninstallation',()=>{
 const c=fresh();c.appLibrary.sortedEntries=()=>[];assert.deepEqual(pins(c,['saved']),['saved']);
});
test('removed app is pruned once a nonempty app inventory is available',()=>{
 const c=fresh();assert.deepEqual(pins(c,['installed','removed']),['installed']);
});
test('conditional command stays pinned even when hidden',()=>{
 const c=fresh();const menu=c.Menu.merge(c.Menu.parse('{"hidden":{"action":"true","when":"false"},"visible":{"action":"true"}}'),[]);
 c.menuItems=menu.items;c.menuOrder=menu.order;c.whenResults={hidden:false};
 assert.equal(c.Menu.leafRows(c.menuItems,c.menuOrder,c.whenResults,{}).length,1);
 assert.deepEqual(pins(c,['cmd:hidden']),['cmd:hidden']);
});
for(const flag of ['menuDefaultsLoaded','menuCustomLoaded']) test('failed menu source preserves unlaunched command pins: '+flag,()=>{
 const c=fresh();c[flag]=false;assert.deepEqual(pins(c,['cmd:unlaunched']),['cmd:unlaunched']);
});
test('removed command is pruned after both menu sources successfully load',()=>{
 const c=fresh();assert.deepEqual(pins(c,['cmd:removed']),[]);
});
test('agent probe in flight or not loaded cannot erase agent pins',()=>{
 for(const ready of [false,true]) {const c=fresh();c.agentsLoaded=ready;c.agentProbe.running=ready;
 assert.deepEqual(pins(c,['agent:other']),['agent:other']);}
});
test('completed agent inventory prunes removed agents',()=>{
 const c=fresh();assert.deepEqual(pins(c,['agent:codex','agent:removed']),['agent:codex']);
});
test('menu parser distinguishes unreadable data from valid empty inventory',()=>{
 const c=fresh();for(const bad of ['','{','[]','null','{"items":[]}']) assert.equal(c.Menu.parse(bad),null);
 assert.deepEqual(plain(c.Menu.parse('{}')),[]);assert.deepEqual(plain(c.Menu.parse('{"items":{}}')),[]);
});
test('saved tab finishing after Favorites selection moves Enter to visible row',()=>{
 const c=fresh();c.resetSelection();c.text=()=>'{"tab":"frequent"}';vm.runInContext(handler('viewFile'),c);
 assert.equal(c.activeTab,'frequent');assert.equal(c.selectedRow().id,'frequent-app');
});
test('restoring an empty tab leaves Enter on the applications grid',()=>{
 const c=fresh();c.frequentRows=[];c.resetSelection();c.restoreView('{"tab":"frequent"}');
 assert.equal(c.selectedRow().id,'all-app');
});
test('late saved preference cannot override an explicit tab choice',()=>{
 const c=fresh();c.showTab('favorites');c.restoreView('{"tab":"frequent"}');assert.equal(c.activeTab,'favorites');
});
test('late saved preference cannot override a collapse gesture',()=>{
 const c=fresh();c.toggleStrip();c.restoreView('{"tab":"frequent"}');assert.equal(c.activeTab,'favorites');assert.equal(c.stripCollapsed,true);
});
test('late saved preference leaves keyboard or mouse selection alone',()=>{
 const c=fresh();c.interacted=true;c.select('all',0);c.restoreView('{"tab":"frequent"}');
 assert.equal(c.activeTab,'favorites');assert.equal(c.selectedRow().id,'all-app');
});
test('initial selection tolerates properties that have not initialized yet',()=>{
 const c=fresh();c.favoriteRows=undefined;c.displayRows=undefined;c.systemRows=undefined;c.resetSelection();assert.equal(c.selectedRow(),null);
});
test('prototype-like application IDs resolve to their own rows and roundtrip',()=>{
 const c=fresh();const ids=['toString','constructor','__proto__','hasOwnProperty'];const rows=ids.map(id=>({id,kind:'app'}));
 assert.deepEqual(plain(c.Favorites.resolve(ids,[rows])),rows);
 assert.deepEqual(plain(c.Favorites.parse(c.Favorites.serialize(ids))),ids);
 assert.deepEqual(plain(c.Favorites.resolve(ids,[[]])),[]);
});

test('prototype-like installed app IDs survive inventory pruning',()=>{
 const c=fresh();const ids=['__proto__','constructor','toString'];
 c.appLibrary.sortedEntries=()=>ids.map(id=>({entry:{id}}));
 assert.deepEqual(pins(c,ids),ids);
});

test('an early click on the default tab saves that choice over an older preference',()=>{
 const c=fresh();c.showTab('favorites');c.restoreView('{"tab":"frequent"}');
 assert.equal(JSON.parse(c.savedView).tab,'favorites');assert.equal(c.activeTab,'favorites');
});

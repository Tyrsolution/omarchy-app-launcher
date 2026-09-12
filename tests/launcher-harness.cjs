const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const dir = path.join(__dirname, '..');
const source = fs.readFileSync(path.join(dir, 'AppGrid.qml'), 'utf8');
function functionSource(name) {
  const start = source.indexOf('  function ' + name + '(');
  if(start < 0) throw new Error('Missing function ' + name);
  return source.slice(start, source.indexOf('\n  }', start) + 4);
}
function handler(id, signal='onLoaded') {
  const block = source.slice(source.indexOf('    id: ' + id));
  const match = block.match(new RegExp('    '+signal+': \\{([\\s\\S]*?)\\n    \\}'));
  if (!match) throw new Error('Missing handler ' + id + '.' + signal);
  return match[1];
}
function lib(file) {
  const c={console};vm.createContext(c);vm.runInContext(fs.readFileSync(path.join(dir,file),'utf8'),c);return c;
}
function fresh() {
  const c={console,Favorites:lib('Favorites.js'),Menu:lib('Menu.js'),Agents:lib('Agents.js'),Usage:lib('Usage.js'),
    panel:{columns:5},appLibrary:{sortedEntries:()=>[{entry:{id:'installed'}}]},installedAgents:['codex'],agentsLoaded:true,agentProbe:{running:false},
    usage:{},favorites:[],favoritesLoaded:true,menuItems:{},menuOrder:[],menuDefaultsLoaded:true,menuCustomLoaded:true,
    favoriteRows:[{id:'pinned-app'}],frequentRows:[{id:'frequent-app'}],displayRows:[{id:'all-app'}],systemRows:[],sessionToggles:[],windowToggles:[],
    activeTab:'favorites',viewInteracted:false,interacted:false,stripCollapsed:false,stripOpen:true,selectedSection:'all',selectedIndex:0,
    favoritesFile:{setText(v){c.savedFavorites=v;}},usageFile:{setText(v){c.savedUsage=v;}},seenFile:{setText(v){c.savedSeen=v;}},viewFile:{setText(v){c.savedView=v;}}};
  c.root=c;vm.createContext(c);
  for (const name of ['liveIdMap','scorableIdMap','markAllSeen','persistUsage','persistFavorites','restoreView','persistView','showTab','toggleStrip',
    'rowsFor','rowAt','selectedRow','select','resetSelection','isStripSection']) vm.runInContext(functionSource(name),c);
  return c;
}
module.exports={fresh,source,functionSource,handler,dir};

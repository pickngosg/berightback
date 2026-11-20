// BeRightBack desktop app (Windows and Mac). It opens the live BeRightBack site in its own window.
const { app, BrowserWindow, Tray, Menu, shell, session } = require('electron');
const path = require('path');
const fs = require('fs');
const SITE = 'https://pickngosg.github.io';
const START = SITE + '/berightback/';
let win = null, tray = null, quitting = false;
const prefFile = () => path.join(app.getPath('userData'), 'prefs.json');
const getPrefs = () => { try { return JSON.parse(fs.readFileSync(prefFile(), 'utf8')); } catch (e) { return {}; } };
const setPref = (k, v) => { try { fs.writeFileSync(prefFile(), JSON.stringify({ ...getPrefs(), [k]: v })); } catch (e) {} };
const autoStart = () => getPrefs().autoStart !== false;           // on unless you switch it off in the tray menu
const applyAutoStart = () => { try { if (app.isPackaged) app.setLoginItemSettings({ openAtLogin: autoStart() }); } catch (e) {} };

if (!app.requestSingleInstanceLock()) { app.quit(); }
else {
  app.on('second-instance', () => { if (win) { win.show(); win.focus(); } });
  app.setAppUserModelId('com.berightback.app');
  app.whenReady().then(() => {
    app.on('web-contents-created', (_e, wc) => {
      wc.setWindowOpenHandler(({ url }) => {
        if (url.startsWith(START) && /[?&]pop=/.test(url)) {   // a chat opened in its own window
          return { action: 'allow', overrideBrowserWindowOptions: { width: 900, height: 680, minWidth: 340, minHeight: 420, autoHideMenuBar: true, backgroundColor: '#abcaec', icon: path.join(__dirname, process.platform === 'win32' ? 'icon.ico' : 'icon-512.png'),
            webPreferences: { contextIsolation: true, nodeIntegration: false, sandbox: true, autoplayPolicy: 'no-user-gesture-required', backgroundThrottling: false } } };
        }
        shell.openExternal(url); return { action: 'deny' };
      });
      wc.on('will-navigate', (e, url) => { if (!url.startsWith(SITE)) { e.preventDefault(); shell.openExternal(url); } });
    });
    applyAutoStart();
    session.defaultSession.setPermissionRequestHandler((wc, permission, cb) => {
      cb(['media', 'notifications', 'clipboard-sanitized-write', 'fullscreen'].includes(permission) && wc.getURL().startsWith(SITE));
    });
    win = new BrowserWindow({ useContentSize: true, width: 1100, height: 780, minWidth: 340, minHeight: 500, center: true, show: false, backgroundColor: '#abcaec', title: 'BeRightBack', icon: path.join(__dirname, process.platform === 'win32' ? 'icon.ico' : 'icon-512.png'), autoHideMenuBar: true,
      webPreferences: { contextIsolation: true, nodeIntegration: false, sandbox: true, autoplayPolicy: 'no-user-gesture-required', backgroundThrottling: false } });
    win.setTitle('BeRightBack');
    win.once('ready-to-show', () => win.show());
    setTimeout(() => { if (win && !win.isVisible()) win.show(); }, 6000);   // safety: never stay hidden
    win.loadURL(START);
    win.webContents.setUserAgent(win.webContents.getUserAgent() + ' BRBpop');   // tells the site this program can open chats in their own windows
    win.on('close', e => { if (!quitting) { e.preventDefault(); win.hide(); } });   // closing the window keeps BeRightBack running in the tray
    tray = new Tray(path.join(__dirname, process.platform === 'win32' ? 'icon.ico' : 'icon-512.png'));
    tray.setToolTip('BeRightBack');
    const buildMenu = () => tray.setContextMenu(Menu.buildFromTemplate([{ label: 'Open BeRightBack', click: () => { win.show(); win.focus(); } },
      { label: 'Start with my computer', type: 'checkbox', checked: autoStart(), click: i => { setPref('autoStart', i.checked); applyAutoStart(); } },
      { label: 'Status', submenu: [['online', 'Online'], ['busy', 'Busy'], ['brb', 'Be Right Back'], ['away', 'Away'], ['phone', 'On The Phone'], ['lunch', 'Out To Lunch'], ['invisible', 'Appear Offline']].map(([k, l]) => ({ label: l, click: () => { try { win.webContents.executeJavaScript("typeof setStatus==='function'&&setStatus('" + k + "')").catch(() => {}); } catch (e) {} } })) },
      { label: 'Sign out', click: () => { try { win.webContents.executeJavaScript("typeof signOut==='function'&&signOut()").catch(() => {}); } catch (e) {} win.show(); win.focus(); } },
      { type: 'separator' },
      { label: 'Quit', click: () => { quitting = true; app.quit(); } }]));
    buildMenu();
    tray.on('click', () => { win.show(); win.focus(); });
  });
  app.on('before-quit', () => { quitting = true; });
}

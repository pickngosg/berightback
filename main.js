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
    applyAutoStart();
    session.defaultSession.setPermissionRequestHandler((wc, permission, cb) => {
      cb(['media', 'notifications', 'clipboard-sanitized-write', 'fullscreen'].includes(permission) && wc.getURL().startsWith(SITE));
    });
    win = new BrowserWindow({ useContentSize: true, width: 425, minWidth: 425, maxWidth: 425, height: 780, minHeight: 500, maximizable: false, center: true, title: 'BeRightBack', icon: path.join(__dirname, process.platform === 'win32' ? 'icon.ico' : 'icon-512.png'), autoHideMenuBar: true,
      webPreferences: { contextIsolation: true, nodeIntegration: false, sandbox: true } });
    win.setTitle('BeRightBack');
    win.on('resize', () => { if (!win.isMaximized() && !win.isFullScreen()) { const [w, h] = win.getContentSize(); if (w !== 425) win.setContentSize(425, h); } });   // keep the window exactly as wide as the contact list
    win.loadURL(START);
    win.webContents.setWindowOpenHandler(({ url }) => { shell.openExternal(url); return { action: 'deny' }; });
    win.webContents.on('will-navigate', (e, url) => { if (!url.startsWith(SITE)) { e.preventDefault(); shell.openExternal(url); } });
    win.on('close', e => { if (!quitting) { e.preventDefault(); win.hide(); } });   // closing the window keeps BeRightBack running in the tray
    tray = new Tray(path.join(__dirname, process.platform === 'win32' ? 'icon.ico' : 'icon-512.png'));
    tray.setToolTip('BeRightBack');
    const buildMenu = () => tray.setContextMenu(Menu.buildFromTemplate([{ label: 'Open BeRightBack', click: () => { win.show(); win.focus(); } },
      { label: 'Start with my computer', type: 'checkbox', checked: autoStart(), click: i => { setPref('autoStart', i.checked); applyAutoStart(); } },
      { label: 'Quit', click: () => { quitting = true; app.quit(); } }]));
    buildMenu();
    tray.on('click', () => { win.show(); win.focus(); });
  });
  app.on('before-quit', () => { quitting = true; });
}

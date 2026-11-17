// BeRightBack desktop app (Windows and Mac). It opens the live BeRightBack site in its own window.
const { app, BrowserWindow, Tray, Menu, shell, session } = require('electron');
const path = require('path');
const SITE = 'https://pickngosg.github.io';
const START = SITE + '/berightback/';
let win = null, tray = null, quitting = false;

if (!app.requestSingleInstanceLock()) { app.quit(); }
else {
  app.on('second-instance', () => { if (win) { win.show(); win.focus(); } });
  app.setAppUserModelId('com.berightback.app');
  app.whenReady().then(() => {
    session.defaultSession.setPermissionRequestHandler((wc, permission, cb) => {
      cb(['media', 'notifications', 'clipboard-sanitized-write', 'fullscreen'].includes(permission) && wc.getURL().startsWith(SITE));
    });
    win = new BrowserWindow({ width: 460, height: 820, minWidth: 360, minHeight: 500, center: true, title: 'BeRightBack', icon: path.join(__dirname, 'icon-512.png'), autoHideMenuBar: true,
      webPreferences: { contextIsolation: true, nodeIntegration: false, sandbox: true } });
    win.loadURL(START);
    win.webContents.setWindowOpenHandler(({ url }) => { shell.openExternal(url); return { action: 'deny' }; });
    win.webContents.on('will-navigate', (e, url) => { if (!url.startsWith(SITE)) { e.preventDefault(); shell.openExternal(url); } });
    win.on('close', e => { if (!quitting) { e.preventDefault(); win.hide(); } });   // closing the window keeps BeRightBack running in the tray
    tray = new Tray(path.join(__dirname, 'icon-512.png').replace('app.asar', 'app.asar'));
    tray.setToolTip('BeRightBack');
    tray.setContextMenu(Menu.buildFromTemplate([{ label: 'Open BeRightBack', click: () => { win.show(); win.focus(); } }, { label: 'Quit', click: () => { quitting = true; app.quit(); } }]));
    tray.on('click', () => { win.show(); win.focus(); });
  });
  app.on('before-quit', () => { quitting = true; });
}

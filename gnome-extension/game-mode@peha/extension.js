import GObject from 'gi://GObject';
import GLib from 'gi://GLib';
import Gio from 'gi://Gio';
import Clutter from 'gi://Clutter';
import St from 'gi://St';
import * as QuickSettings from 'resource:///org/gnome/shell/ui/quickSettings.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import { Extension, gettext as _ } from 'resource:///org/gnome/shell/extensions/extension.js';

// Themed icon names only — deliberately not the snap-installed .png/.svg
// (e.g. /snap/steam/current/...): loading those means a GLib.file_test() +
// GFileIcon read against a snap's squashfs mount, done synchronously while
// building the picker. If that mount is slow to activate (snap
// autofs/squashfs on a cold cache), it blocks gnome-shell's single UI thread
// for however long that takes — indistinguishable from the whole session
// hanging. Themed icons are already resolved from the icon theme cache, no
// filesystem access outside it.
const STEAM_ICON_NAME = 'input-gaming-symbolic';
const RETROARCH_ICON_NAME = 'applications-games-symbolic';

// Linux joystick API (linux/joystick.h): struct js_event is 8 bytes,
// { __u32 time; __s16 value; __u8 type; __u8 number; }, little-endian.
const JS_EVENT_BUTTON = 0x01;
const JS_EVENT_AXIS = 0x02;
const JS_EVENT_INIT = 0x80;
const AXIS_THRESHOLD = 16000;

// org.gnome.Mutter.DisplayConfig: same D-Bus API GNOME Settings > Displays uses.
// Declared inline instead of shipping a separate XML file, single-extension use.
const DisplayConfigIface = `
<node>
  <interface name="org.gnome.Mutter.DisplayConfig">
    <method name="GetCurrentState">
      <arg name="serial" direction="out" type="u"/>
      <arg name="monitors" direction="out" type="a((ssss)a(siiddada{sv})a{sv})"/>
      <arg name="logical_monitors" direction="out" type="a(iiduba(ssss)a{sv})"/>
      <arg name="properties" direction="out" type="a{sv}"/>
    </method>
    <method name="ApplyMonitorsConfig">
      <arg name="serial" direction="in" type="u"/>
      <arg name="method" direction="in" type="u"/>
      <arg name="logical_monitors" direction="in" type="a(iiduba(ssa{sv}))"/>
      <arg name="properties" direction="in" type="a{sv}"/>
    </method>
  </interface>
</node>`;
const DisplayConfigProxy = Gio.DBusProxy.makeProxyWrapper(DisplayConfigIface);

// Reads raw joystick events off /dev/input/jsN so the picker widget is
// controllable from a gamepad without any extra daemon or dependency
// (uaccess udev tag already grants the logged-in user read access, see README).
// Button/axis numbers are a best-effort v1 mapping (0 = confirm, 1 = cancel,
// axis 0/6 = left stick / d-pad X) — refine once tested against real hardware.
class GamepadWatcher {
    constructor({ onLeft, onRight, onConfirm, onCancel }) {
        this._onLeft = onLeft;
        this._onRight = onRight;
        this._onConfirm = onConfirm;
        this._onCancel = onCancel;
        this._stream = null;
        this._cancellable = new Gio.Cancellable();
        this._open();
    }

    _open() {
        for (let i = 0; i < 4; i++) {
            const path = `/dev/input/js${i}`;
            if (!GLib.file_test(path, GLib.FileTest.EXISTS))
                continue;
            try {
                this._stream = Gio.File.new_for_path(path).read(null);
                this._readNext();
                return;
            } catch (e) {
                console.error(`Game Mode: cannot open ${path}: ${e}`);
            }
        }
    }

    _readNext() {
        if (!this._stream)
            return;
        this._stream.read_bytes_async(8, GLib.PRIORITY_DEFAULT, this._cancellable, (stream, result) => {
            let bytes;
            try {
                bytes = stream.read_bytes_finish(result);
            } catch (e) {
                return; // closed or cancelled
            }
            if (!bytes || bytes.get_size() < 8)
                return;
            this._handleEvent(bytes);
            this._readNext();
        });
    }

    _handleEvent(bytes) {
        try {
            const data = bytes.get_data();
            const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
            const value = view.getInt16(4, true);
            const type = view.getUint8(6) & ~JS_EVENT_INIT;
            const number = view.getUint8(7);

            if (type === JS_EVENT_BUTTON && value === 1) {
                if (number === 0)
                    this._onConfirm();
                else if (number === 1)
                    this._onCancel();
            } else if (type === JS_EVENT_AXIS && (number === 0 || number === 6)) {
                if (value < -AXIS_THRESHOLD)
                    this._onLeft();
                else if (value > AXIS_THRESHOLD)
                    this._onRight();
            }
        } catch (e) {
            console.error(`Game Mode: gamepad event parse error: ${e}`);
        }
    }

    destroy() {
        this._cancellable.cancel();
        if (this._stream) {
            try {
                this._stream.close(null);
            } catch (e) {
                // already closed
            }
            this._stream = null;
        }
    }
}

// Small full-screen overlay to pick Steam or RetroArch.
//
// Deliberately NOT a Main.pushModal() grab. A first version used one, and a
// bug in this dialog's own key/click handling combined with that exclusive
// grab left the whole session completely unresponsive (no mouse, no
// keyboard, not even Escape) — the only way out was a hard power-off. Using
// Main.layoutManager.addChrome() instead means Super/Alt+Tab/workspace
// switching keep working even if this dialog misbehaves again. The
// auto-cancel timeout below is a second, independent safety net on top of
// that: this dialog can never stay stuck on screen forever, no matter what.
const AUTO_CANCEL_SECONDS = 60;

class GamePickerDialog {
    constructor({ onChoice, onCancel }) {
        this._onChoice = onChoice;
        this._onCancel = onCancel;
        this._closed = false;

        const monitor = Main.layoutManager.primaryMonitor;

        this._overlay = new St.Widget({
            style_class: 'game-mode-picker-overlay',
            layout_manager: new Clutter.BinLayout(),
            reactive: true,
            can_focus: true,
            x: monitor.x,
            y: monitor.y,
            width: monitor.width,
            height: monitor.height,
        });

        const box = new St.BoxLayout({
            style_class: 'game-mode-picker',
            vertical: true,
            x_align: Clutter.ActorAlign.CENTER,
            y_align: Clutter.ActorAlign.CENTER,
        });

        box.add_child(new St.Label({
            style_class: 'game-mode-picker-title',
            text: _('Choose what to launch'),
            x_align: Clutter.ActorAlign.CENTER,
        }));

        const buttonBox = new St.BoxLayout({
            style_class: 'game-mode-picker-buttons',
            x_align: Clutter.ActorAlign.CENTER,
        });
        box.add_child(buttonBox);

        this._buttons = [
            this._createButton(STEAM_ICON_NAME, _('Steam'), 'steam'),
            this._createButton(RETROARCH_ICON_NAME, _('RetroArch'), 'retroarch'),
        ];
        this._buttons.forEach(button => buttonBox.add_child(button));
        this._focusIndex = 0;

        this._overlay.add_child(box);

        // Key focus stays on the overlay itself, never on a button — St.Button
        // swallows its own key/press events (that's how it detects clicks and
        // Return/Space activation), so focusing a button meant Escape never
        // reached this handler at all. Button highlighting below is purely
        // visual (a CSS pseudo-class), not real Clutter focus.
        this._keyPressId = this._overlay.connect('key-press-event', this._onKeyPress.bind(this));
        // A press that bubbles up to the overlay itself (rather than being
        // consumed by a button) means it landed on empty backdrop: cancel.
        // Only stop the event when we actually act on it — unconditionally
        // stopping here (even for clicks whose source was a button) is
        // suspected to have been swallowing the buttons' own clicks; letting
        // everything else propagate is strictly safer regardless.
        this._buttonPressId = this._overlay.connect('button-press-event', (actor, event) => {
            if (event.get_source() === this._overlay) {
                this._onCancel();
                return Clutter.EVENT_STOP;
            }
            return Clutter.EVENT_PROPAGATE;
        });

        // Confirmed via journalctl (2026-08-07): `affectsInputRegion` throws
        // "Unrecognized parameter" on this shell version (50.1) — addChrome's
        // Params.parse() is strict about its param set and it isn't one of
        // them here. A reactive actor added via addChrome already
        // participates in the input region by default, so it isn't needed.
        Main.layoutManager.addChrome(this._overlay, {
            trackFullscreen: true,
        });

        global.stage.set_key_focus(this._overlay);
        this._updateFocus();

        // Belt-and-braces: the Quick Settings panel's own closing animation
        // can steal key focus back a moment after we grab it above. Re-assert
        // once on the next tick, after that settles.
        this._refocusId = GLib.idle_add(GLib.PRIORITY_DEFAULT, () => {
            this._refocusId = null;
            if (!this._closed)
                global.stage.set_key_focus(this._overlay);
            return GLib.SOURCE_REMOVE;
        });

        this._gamepad = new GamepadWatcher({
            onLeft: () => this._moveFocus(-1),
            onRight: () => this._moveFocus(1),
            onConfirm: () => this._confirm(),
            onCancel: () => this._onCancel(),
        });

        this._timeoutId = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, AUTO_CANCEL_SECONDS, () => {
            this._timeoutId = null;
            this._onCancel();
            return GLib.SOURCE_REMOVE;
        });
    }

    _createButton(iconName, label, appId) {
        const button = new St.Button({
            style_class: 'game-mode-picker-button',
            can_focus: true,
            reactive: true,
        });

        const content = new St.BoxLayout({ vertical: true, x_align: Clutter.ActorAlign.CENTER });
        const icon = new St.Icon({ style_class: 'game-mode-picker-icon', icon_name: iconName });
        content.add_child(icon);
        content.add_child(new St.Label({ style_class: 'game-mode-picker-label', text: label }));
        button.set_child(content);

        button.connect('clicked', () => {
            console.log(`Game Mode: [timing] button 'clicked' fired for ${appId}`);
            this._onChoice(appId);
        });
        button._appId = appId;
        return button;
    }

    _updateFocus() {
        this._buttons.forEach((button, index) => {
            if (index === this._focusIndex)
                button.add_style_pseudo_class('focus');
            else
                button.remove_style_pseudo_class('focus');
        });
    }

    _moveFocus(delta) {
        this._focusIndex = (this._focusIndex + delta + this._buttons.length) % this._buttons.length;
        this._updateFocus();
    }

    _confirm() {
        this._onChoice(this._buttons[this._focusIndex]._appId);
    }

    _onKeyPress(actor, event) {
        switch (event.get_key_symbol()) {
        case Clutter.KEY_Left:
            this._moveFocus(-1);
            return Clutter.EVENT_STOP;
        case Clutter.KEY_Right:
            this._moveFocus(1);
            return Clutter.EVENT_STOP;
        case Clutter.KEY_Return:
        case Clutter.KEY_KP_Enter:
        case Clutter.KEY_space:
            this._confirm();
            return Clutter.EVENT_STOP;
        case Clutter.KEY_Escape:
            this._onCancel();
            return Clutter.EVENT_STOP;
        default:
            return Clutter.EVENT_PROPAGATE;
        }
    }

    close() {
        if (this._closed)
            return;
        this._closed = true;

        if (this._timeoutId) {
            GLib.source_remove(this._timeoutId);
            this._timeoutId = null;
        }
        if (this._refocusId) {
            GLib.source_remove(this._refocusId);
            this._refocusId = null;
        }
        if (this._gamepad) {
            this._gamepad.destroy();
            this._gamepad = null;
        }
        if (this._keyPressId) {
            this._overlay.disconnect(this._keyPressId);
            this._keyPressId = null;
        }
        if (this._buttonPressId) {
            this._overlay.disconnect(this._buttonPressId);
            this._buttonPressId = null;
        }
        Main.layoutManager.removeChrome(this._overlay);
        this._overlay.destroy();
    }
}

// All Game Mode business logic: display switch, dedicated workspace, app
// launch/tracking. Kept separate from the QuickToggle so the toggle stays a
// thin view over this state, same split as elsewhere in this extension.
class GameModeManager {
    constructor(toggle) {
        this._toggle = toggle;
        // Nothing DisplayConfig-related is built here. Three targeted fixes
        // around this proxy (sync-to-async calls, sync-to-async construction,
        // a bad addChrome param) all failed to stop a freeze that reproduces
        // on every enable(), before the toggle is ever clicked — so instead
        // of chasing the exact mechanism further, the proxy is now built
        // lazily in _getDisplayConfig() below, on first actual use. Since
        // display detection only ever happens after a picker choice (see
        // _onChoicePicked()), this means literally nothing D-Bus/DisplayConfig
        // related runs at enable()/login time at all anymore.
        this._displayConfig = null;
        this._active = false;
        this._picker = null;
        this._appProcess = null;
        this._savedLogicalMonitors = null;
        this._gamingWorkspace = null;
        this._savedWorkspaceIndex = 0;
    }

    _getDisplayConfig(callback) {
        if (this._displayConfig) {
            callback(this._displayConfig, null);
            return;
        }
        new DisplayConfigProxy(Gio.DBus.session,
            'org.gnome.Mutter.DisplayConfig', '/org/gnome/Mutter/DisplayConfig',
            (proxy, error) => {
                if (error) {
                    callback(null, error);
                    return;
                }
                this._displayConfig = proxy;
                callback(proxy, null);
            });
    }

    toggle() {
        if (this._active)
            this.deactivate();
        else
            this.activate();
    }

    // Deliberately shows the picker *before* touching the display or the
    // workspace: if anything about the picker goes wrong, the user is still
    // sitting on their normal desktop and can just deactivate, instead of
    // being stranded on a freshly-created empty workspace with the internal
    // screen off. The disruptive part only runs once a real choice is made,
    // in _onChoicePicked() below.
    activate() {
        if (this._active)
            return;
        this._active = true;

        this._toggle.checked = true;
        this._toggle.subtitle = _('Choosing…');

        // The click that got us here happened inside the still-open Quick
        // Settings popup, which holds its own input grab — without closing
        // it, that grab keeps competing with the picker below for both
        // clicks and key presses (Escape, button clicks), which is why
        // neither worked. Try the known API names across shell versions.
        try {
            Main.panel.closeQuickSettings();
        } catch (e) {
            try {
                Main.panel.statusArea.quickSettings.menu.close();
            } catch (e2) {
                console.error(`Game Mode: could not close Quick Settings panel: ${e2}`);
            }
        }

        try {
            this._picker = new GamePickerDialog({
                onChoice: appId => this._onChoicePicked(appId),
                onCancel: () => this.deactivate(),
            });
        } catch (e) {
            console.error(`Game Mode: failed to open picker: ${e}`);
            this._active = false;
            this._toggle.checked = false;
            this._toggle.subtitle = _('Off');
        }
    }

    _onChoicePicked(appId) {
        if (this._picker) {
            this._picker.close();
            this._picker = null;
        }

        // The HDMI switch is async and its callback runs the rest of this
        // step (workspace + launch) — see _switchToHdmi()'s comment for why
        // this can't be a synchronous D-Bus call.
        this._switchToHdmi(error => {
            if (error)
                console.error(`Game Mode: display switch failed: ${error}`);

            const workspaceManager = global.workspace_manager;
            this._savedWorkspaceIndex = workspaceManager.get_active_workspace_index();
            this._gamingWorkspace = workspaceManager.append_new_workspace(true, global.get_current_time());

            this._launch(appId);
        });
    }

    deactivate() {
        if (!this._active)
            return;
        this._active = false;

        if (this._appProcess) {
            try {
                this._appProcess.send_signal(15); // SIGTERM; no-op if already exited
            } catch (e) {
                // process already gone
            }
            this._appProcess = null;
        }

        if (this._picker) {
            this._picker.close();
            this._picker = null;
        }

        if (this._savedLogicalMonitors) {
            const toRestore = this._savedLogicalMonitors;
            this._savedLogicalMonitors = null;
            this._applyLogicalMonitors(toRestore, error => {
                if (error)
                    console.error(`Game Mode: display restore failed: ${error}`);
            });
        }

        const workspaceManager = global.workspace_manager;
        if (this._gamingWorkspace) {
            const saved = workspaceManager.get_workspace_by_index(this._savedWorkspaceIndex);
            if (saved)
                saved.activate(global.get_current_time());
            workspaceManager.remove_workspace(this._gamingWorkspace, global.get_current_time());
            this._gamingWorkspace = null;
        }

        this._toggle.checked = false;
        this._toggle.subtitle = _('Off');
    }

    destroy() {
        this.deactivate();
    }

    // org.gnome.Mutter.DisplayConfig is implemented by Mutter, which runs
    // *inside this same gnome-shell process* — a Sync() call here is a
    // same-process, same-thread D-Bus round trip: the caller blocks the only
    // thread that could ever service and reply to that call. Best case it's
    // merely slow; worst case (and what actually happened, twice) the whole
    // shell hangs. Every call to this proxy in this file must go through the
    // *Remote() async form, never *Sync().
    _switchToHdmi(callback) {
        this._getDisplayConfig((displayConfig, proxyError) => {
            if (proxyError) {
                this._savedLogicalMonitors = null;
                callback(proxyError);
                return;
            }
            displayConfig.GetCurrentStateRemote((result, error) => {
                if (error) {
                    this._savedLogicalMonitors = null;
                    callback(error);
                    return;
                }

                const [, monitors, logicalMonitors] = result;
                const hdmi = monitors.find(([spec]) => spec[0].startsWith('HDMI'));

                if (!hdmi) {
                    this._savedLogicalMonitors = null;
                    callback(null);
                    return;
                }

                this._savedLogicalMonitors = this._toRestoreConfig(logicalMonitors, monitors);

                const [spec, modes] = hdmi;
                const connector = spec[0];
                const preferred = modes.find(([, , , , , , props]) => props['is-preferred']?.deep_unpack());
                const mode = preferred ?? modes[0];
                if (!mode) {
                    callback(null);
                    return;
                }
                const [modeId, , , , preferredScale] = mode;

                this._applyLogicalMonitors(
                    [[0, 0, preferredScale || 1.0, 0, true, [[connector, modeId, {}]]]], callback);
            });
        });
    }

    // Rebuilds an ApplyMonitorsConfig-shaped layout from a GetCurrentState
    // snapshot: logical_monitors only carries (connector, vendor, product,
    // serial) per monitor, not the mode id ApplyMonitorsConfig needs, so the
    // current mode id has to be looked up per-connector from `monitors`.
    _toRestoreConfig(logicalMonitors, monitors) {
        const currentModeByConnector = new Map();
        for (const [spec, modes] of monitors) {
            const current = modes.find(([, , , , , , props]) => props['is-current']?.deep_unpack());
            if (current)
                currentModeByConnector.set(spec[0], current[0]);
        }

        return logicalMonitors.map(([x, y, scale, transform, primary, monitorSpecs]) => {
            const monitorConfigs = monitorSpecs
                .map(spec => {
                    const modeId = currentModeByConnector.get(spec[0]);
                    return modeId ? [spec[0], modeId, {}] : null;
                })
                .filter(config => config !== null);
            return [x, y, scale, transform, primary, monitorConfigs];
        });
    }

    _applyLogicalMonitors(logicalMonitors, callback) {
        this._getDisplayConfig((displayConfig, proxyError) => {
            if (proxyError) {
                callback(proxyError);
                return;
            }
            displayConfig.GetCurrentStateRemote((result, error) => {
                if (error) {
                    callback(error);
                    return;
                }
                const [serial] = result;
                displayConfig.ApplyMonitorsConfigRemote(
                    serial, 1 /* temporary */, logicalMonitors, {},
                    (applyResult, applyError) => callback(applyError || null));
            });
        });
    }

    _launch(appId) {
        console.log(`Game Mode: [timing] _launch(${appId}) called`);
        const argv = appId === 'steam'
            ? ['snap', 'run', 'steam', '-bigpicture']
            : ['snap', 'run', 'retroarch', '-f'];

        try {
            const process = Gio.Subprocess.new(argv, Gio.SubprocessFlags.NONE);
            console.log(`Game Mode: [timing] Subprocess.new(${argv.join(' ')}) succeeded`);
            this._appProcess = process;
            process.wait_async(null, (proc, result) => {
                try {
                    proc.wait_finish(result);
                } catch (e) {
                    // ignore, we only care that it exited
                }
                if (this._appProcess === proc) {
                    this._appProcess = null;
                    this.deactivate();
                }
            });
            this._toggle.subtitle = appId === 'steam' ? _('Steam') : _('RetroArch');
        } catch (e) {
            console.error(`Game Mode: failed to launch ${appId}: ${e}`);
            this.deactivate();
        }
    }
}

const GameModeToggle = GObject.registerClass(
class GameModeToggle extends QuickSettings.QuickToggle {
    _init() {
        super._init({
            title: _('Game Mode'),
            iconName: 'input-gaming-symbolic',
            subtitle: _('Off'),
        });
    }
});

const GameModeIndicator = GObject.registerClass(
class GameModeIndicator extends QuickSettings.SystemIndicator {
    _init() {
        let t = GLib.get_monotonic_time();
        const mark = (label) => {
            const now = GLib.get_monotonic_time();
            console.log(`Game Mode: [timing] ${label}: ${(now - t) / 1000}ms`);
            t = now;
        };

        super._init();
        mark('SystemIndicator super._init()');
        this._toggle = new GameModeToggle();
        mark('GameModeToggle ctor');
        this._manager = new GameModeManager(this._toggle);
        mark('GameModeManager ctor');
        this._toggle.connect('clicked', () => this._manager.toggle());
        this.quickSettingsItems.push(this._toggle);
        mark('connect + quickSettingsItems.push');
    }

    destroy() {
        if (this._manager) {
            this._manager.destroy();
            this._manager = null;
        }
        if (this._toggle) {
            this._toggle.destroy();
            this._toggle = null;
        }
        super.destroy();
    }
});

export default class GameModeExtension extends Extension {
    enable() {
        const t0 = GLib.get_monotonic_time();
        console.log('Game Mode: [timing] enable() start');
        this._indicator = new GameModeIndicator();
        const t1 = GLib.get_monotonic_time();
        console.log(`Game Mode: [timing] new GameModeIndicator(): ${(t1 - t0) / 1000}ms`);
        Main.panel.statusArea.quickSettings.addExternalIndicator(this._indicator);
        const t2 = GLib.get_monotonic_time();
        console.log(`Game Mode: [timing] addExternalIndicator(): ${(t2 - t1) / 1000}ms`);
        console.log(`Game Mode: [timing] enable() total: ${(t2 - t0) / 1000}ms`);
    }

    disable() {
        if (this._indicator) {
            this._indicator.destroy();
            this._indicator = null;
        }
    }
}

import GObject from 'gi://GObject';
import GLib from 'gi://GLib';
import Gio from 'gi://Gio';
import * as QuickSettings from 'resource:///org/gnome/shell/ui/quickSettings.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import { Extension, gettext as _ } from 'resource:///org/gnome/shell/extensions/extension.js';

const THRESHOLD_PATH = '/sys/class/power_supply/BAT1/charge_control_end_threshold';
const CONF_PATH = `${GLib.get_home_dir()}/.config/charge_limit.conf`;

// GLib.file_set_contents() writes via a temp file + rename (atomic write), a
// pattern sysfs refuses (can't create a new dentry under /sys). So the
// existing file has to be opened directly instead.
function writeSysfs(path, value) {
    const file = Gio.File.new_for_path(path);
    const ioStream = file.open_readwrite(null);
    ioStream.get_output_stream().write(value, null);
    ioStream.close(null);
}

const BatteryChargeToggle = GObject.registerClass(
class BatteryChargeToggle extends QuickSettings.QuickToggle {
    _init(extensionObject) {
        super._init({
            title: _('Full Charge'),
            iconName: 'battery-level-100-charged-symbolic',
        });

        this._extension = extensionObject;

        // Set the initial state
        this._updateState();

        // Listen for user clicks
        this.connect('clicked', () => {
            this._toggleLimit();
        });
    }

    _updateState() {
        try {
            let limit = '80'; // Limited to 80% by default

            // Try reading the persistent config file
            if (GLib.file_test(CONF_PATH, GLib.FileTest.EXISTS)) {
                const [success, contents] = GLib.file_get_contents(CONF_PATH);
                if (success) {
                    limit = new TextDecoder().decode(contents).trim();
                }
            } else {
                // If the config doesn't exist yet, initialize it to 80
                GLib.file_set_contents(CONF_PATH, '80');
                if (GLib.file_test(THRESHOLD_PATH, GLib.FileTest.EXISTS)) {
                    writeSysfs(THRESHOLD_PATH, '80');
                }
            }

            // If the limit is 100, "Full Charge" is enabled (checked = true)
            this.checked = (limit === '100');
            this.subtitle = this.checked ? _('On (100%)') : _('Limited (80%)');

            // Sync the physical sysfs state if needed
            if (GLib.file_test(THRESHOLD_PATH, GLib.FileTest.EXISTS)) {
                const [success, sysfsContents] = GLib.file_get_contents(THRESHOLD_PATH);
                if (success) {
                    const currentSysfs = new TextDecoder().decode(sysfsContents).trim();
                    if (currentSysfs !== limit) {
                        writeSysfs(THRESHOLD_PATH, limit);
                    }
                }
            }
        } catch (e) {
            console.error(e);
            this.subtitle = _('Error');
        }
    }

    _toggleLimit() {
        try {
            const newValue = this.checked ? '100' : '80';

            // Update the persistent config
            GLib.file_set_contents(CONF_PATH, newValue);

            // Update the physical sysfs value
            if (GLib.file_test(THRESHOLD_PATH, GLib.FileTest.EXISTS)) {
                writeSysfs(THRESHOLD_PATH, newValue);
            }

            this.subtitle = this.checked ? _('On (100%)') : _('Limited (80%)');
        } catch (e) {
            console.error(e);
            this.subtitle = _('Error');
        }
    }
});

const BatteryChargeIndicator = GObject.registerClass(
class BatteryChargeIndicator extends QuickSettings.SystemIndicator {
    _init(extensionObject) {
        super._init();
        this._toggle = new BatteryChargeToggle(extensionObject);
        this.quickSettingsItems.push(this._toggle);
    }

    destroy() {
        if (this._toggle) {
            this._toggle.destroy();
            this._toggle = null;
        }
        super.destroy();
    }
});

export default class BatteryChargeExtension extends Extension {
    enable() {
        this._indicator = new BatteryChargeIndicator(this);
        Main.panel.statusArea.quickSettings.addExternalIndicator(this._indicator);
    }

    disable() {
        if (this._indicator) {
            this._indicator.destroy();
            this._indicator = null;
        }
    }
}

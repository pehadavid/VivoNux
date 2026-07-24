import GObject from 'gi://GObject';
import GLib from 'gi://GLib';
import Gio from 'gi://Gio';
import * as QuickSettings from 'resource:///org/gnome/shell/ui/quickSettings.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import { Extension } from 'resource:///org/gnome/shell/extensions/extension.js';

const THRESHOLD_PATH = '/sys/class/power_supply/BAT1/charge_control_end_threshold';
const CONF_PATH = `${GLib.get_home_dir()}/.config/charge_limit.conf`;

// GLib.file_set_contents() écrit via un fichier temporaire + rename (écriture
// atomique), un schéma que sysfs refuse (impossible de créer un nouveau
// dentry dans /sys). Il faut donc ouvrir le fichier existant directement.
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
            title: 'Charge Complète',
            iconName: 'battery-level-100-charged-symbolic',
        });

        this._extension = extensionObject;

        // Définir l'état initial
        this._updateState();

        // Écouter les clics de l'utilisateur
        this.connect('clicked', () => {
            this._toggleLimit();
        });
    }

    _updateState() {
        try {
            let limit = '80'; // Par défaut, limité à 80%
            
            // Tente de lire le fichier de config persistant
            if (GLib.file_test(CONF_PATH, GLib.FileTest.EXISTS)) {
                const [success, contents] = GLib.file_get_contents(CONF_PATH);
                if (success) {
                    limit = new TextDecoder().decode(contents).trim();
                }
            } else {
                // Si la config n'existe pas, on l'initialise à 80
                GLib.file_set_contents(CONF_PATH, '80');
                if (GLib.file_test(THRESHOLD_PATH, GLib.FileTest.EXISTS)) {
                    writeSysfs(THRESHOLD_PATH, '80');
                }
            }

            // Si la limite est 100, la "Charge Complète" est activée (checked = true)
            this.checked = (limit === '100');
            this.subtitle = this.checked ? 'Actif (100%)' : 'Limité (80%)';
            
            // Synchronise l'état physique du sysfs si nécessaire
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
            this.subtitle = 'Erreur';
        }
    }

    _toggleLimit() {
        try {
            const newValue = this.checked ? '100' : '80';
            
            // Met à jour la config persistante
            GLib.file_set_contents(CONF_PATH, newValue);
            
            // Met à jour le sysfs physique
            if (GLib.file_test(THRESHOLD_PATH, GLib.FileTest.EXISTS)) {
                writeSysfs(THRESHOLD_PATH, newValue);
            }
            
            this.subtitle = this.checked ? 'Actif (100%)' : 'Limité (80%)';
        } catch (e) {
            console.error(e);
            this.subtitle = 'Erreur';
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

import Foundation

/// Per-button "special function" (`sw_sp_func_no`, 0..13). These are built-in device
/// actions — not keystrokes and not scripts — for switching mode / dial function.
/// Values and meanings are from the firmware (`app.h` `SW_SP_FUNC_*`).
public enum SpecialFunction {
    /// Highest valid value (firmware `SW_SP_FUNC_NUM`).
    public static let maxValue: UInt8 = 13

    /// Human-readable name for a special-function number (0 = none).
    public static func name(_ no: UInt8) -> String {
        switch no {
        case 0: return "None"
        case 1: return "Change mode (cycle)"
        case 2: return "Switch to Mode 1"
        case 3: return "Switch to Mode 2"
        case 4: return "Switch to Mode 3"
        case 5: return "Dial function 1"
        case 6: return "Dial function 2"
        case 7: return "Dial function 3"
        case 8: return "Dial function 4"
        case 9: return "Dial function 1 (while held)"
        case 10: return "Dial function 2 (while held)"
        case 11: return "Dial function 3 (while held)"
        case 12: return "Dial function 4 (while held)"
        case 13: return "Change dial function (cycle)"
        default: return "Unknown (\(no))"
        }
    }

    /// All selectable values, 0...13, for a picker.
    public static let all: [UInt8] = Array(0...maxValue)
}

import Foundation

extension ScanPreset {
    var durationDescription: String {
        switch self {
        case .p2188Idle: return "About 3–5 minutes per fuel"
        case .coldStart: return "About 5 minutes"
        case .warmIdle: return "3–5 minutes"
        case .rpm2500: return "30–60 seconds"
        case .road: return "10–20 minutes"
        case .allSupported: return "Duration depends on vehicle and protocol"
        }
    }

    var guidedSteps: [String] {
        switch self {
        case .p2188Idle:
            return [
                "Warm coolant to at least 80 °C. Turn A/C and large electrical loads off.",
                "Record 90 seconds at stable idle and tap the Idle marker.",
                "In Park or Neutral, hold 2300–2700 RPM for about 45 seconds and tap the 2500 RPM marker.",
                "For an LPG vehicle, record separate gasoline and LPG sessions at comparable temperature and load. Mark every fuel switch."
            ]
        case .coldStart:
            return [
                "Leave the engine cold long enough for coolant temperature to approach ambient temperature.",
                "Turn ignition on and start logging before cranking.",
                "Start the engine without touching the accelerator and continue until idle begins to stabilize.",
                "Mark any delayed start, stumble, smoke, smell or vibration when it occurs."
            ]
        case .warmIdle:
            return [
                "Warm the engine fully and park in a ventilated location.",
                "Turn A/C and large electrical loads off for the baseline.",
                "Log a stable idle for 3–5 minutes and mark every symptom.",
                "Optionally repeat with A/C on to expose load-related behavior."
            ]
        case .rpm2500:
            return [
                "Warm the engine fully and keep the vehicle stationary.",
                "Select Park or Neutral and apply the parking brake.",
                "Raise speed smoothly to 2300–2700 RPM and hold for 30–60 seconds.",
                "Stop immediately if temperature, noise, vibration or warning indicators become abnormal."
            ]
        case .road:
            return [
                "Mount the iPhone securely before moving and start logging while parked.",
                "Drive a normal low-risk route with idle, steady cruise, gentle acceleration and deceleration.",
                "Do not touch the phone while moving; use a passenger for markers when available.",
                "Stop and save only after the vehicle is safely parked."
            ]
        case .allSupported:
            return [
                "Keep ignition voltage stable and the adapter connected.",
                "Use this after a Full snapshot has discovered the vehicle's supported PIDs.",
                "Allow at least one complete cycle; slow ISO/KWP vehicles may take substantially longer.",
                "Unknown signals remain raw-only until a verified data pack is installed."
            ]
        }
    }

    var safetyNotice: String? {
        switch self {
        case .road:
            return "Driving safety takes priority. Never hold or operate the iPhone while the vehicle is moving."
        case .rpm2500, .p2188Idle:
            return "Perform stationary RPM tests only in Park/Neutral, with the parking brake applied and adequate ventilation."
        case .coldStart:
            return "Do not run the engine in an enclosed space."
        case .warmIdle:
            return "Use adequate ventilation and watch coolant temperature."
        case .allSupported:
            return nil
        }
    }
}

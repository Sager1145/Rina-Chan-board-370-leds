import Foundation

/// Precomputed `LipSyncProfile.synthesized` output for `LipSyncConfig.default`.
///
/// `LipSyncProfile.synthesized` runs a full source-filter vowel synthesis and
/// MFCC pass for five vowels — cheap once warmed up, but ~20 ms in a debug
/// build, all of it on the main actor during `LipSyncModel.init` if no
/// profile is stored yet. Baking the default-config result in as literals
/// turns that into a dictionary lookup.
///
/// Regenerate with:
/// `RINA_REGENERATE_LIPSYNC_PROFILES=1 swift test --filter LipSyncDefaultProfilesTests`
enum LipSyncDefaultProfileData {
    static let standard: [String: [Float]] = [
        "a": [0.67456335, -0.6537047, -0.21443665, -0.16401404, -0.08445965, 0.1574361, 0.019161332, -0.08425928, 0.028077163, 0.052114997, -0.03887616, -0.018675316],
        "i": [0.4214016, -0.5040875, 0.67725664, -0.17188333, -0.19033861, 0.091953754, -0.096213475, -0.10494344, -0.053390224, -0.07278435, -0.009921552, -0.08303687],
        "u": [0.9293872, -0.24051142, -0.07689611, -0.027683448, -0.16191801, 0.06266602, 0.0803643, -0.13155268, -0.11624794, -0.022596603, -0.053810038, -0.029759021],
        "e": [0.5085774, -0.74607676, 0.15634741, -0.052727055, -0.37678534, -0.08948186, 0.036921255, -0.001485955, 0.048174612, 0.034653798, 0.016034812, 0.04873888],
        "o": [0.7865642, -0.3492174, -0.28471112, -0.28366926, -0.27688965, 0.06866693, 0.09674154, -0.046641953, 0.030676354, 0.039666258, -0.03423928, 0.03508797],
    ]

    static let male: [String: [Float]] = [
        "a": [0.7005911, -0.59269255, -0.27600265, -0.18356878, -0.096424386, 0.08372386, 0.121808775, -0.09980609, -0.026849931, 0.051844593, -0.010060241, -0.058281243],
        "i": [0.4978534, -0.5631167, 0.58752203, -0.024683863, -0.24788219, 0.0629518, -0.01419945, -0.12782726, -0.042847283, -0.054332953, -0.018746966, -0.04648429],
        "u": [0.9409464, -0.2144668, -0.07850725, -0.041555602, -0.13405408, -0.016532581, 0.10191729, -0.07408733, -0.14057566, -0.054632507, -0.03486552, -0.051496387],
        "e": [0.5953622, -0.70861953, 0.08025834, 0.04993336, -0.3256522, -0.1620492, 0.00961995, -0.0023303921, 0.021132972, 0.023442712, -0.0057624937, 0.03210582],
        "o": [0.8362705, -0.2909094, -0.2564014, -0.21224026, -0.29416832, -0.0102645, 0.116454184, -0.03185417, -0.018703805, 0.052033633, -0.01755617, -0.025564767],
    ]

    static let female: [String: [Float]] = [
        "a": [0.5660513, -0.75182676, -0.18996596, -0.19628417, -0.014478894, 0.16577351, -0.03592341, -0.07134209, 0.05544521, -0.007835597, -0.048275024, 0.013827018],
        "i": [0.23902898, -0.5032712, 0.7125136, -0.3648301, -0.12395634, 0.093236595, -0.133086, -0.050088782, -0.025633754, 0.013941505, -0.0021203242, -0.06059368],
        "u": [0.8775695, -0.40016752, 0.009120686, -0.1277828, -0.09713056, 0.10641172, 0.010576614, -0.16305172, -0.060054284, -0.0015470334, -0.022997975, 0.041626085],
        "e": [0.41255823, -0.7737054, 0.21507953, -0.20313518, -0.36113748, -0.04094334, 0.03695716, 0.009480322, 0.06850039, 0.048470527, 0.055193827, 0.0034859846],
        "o": [0.7532616, -0.50499856, -0.17673402, -0.30313495, -0.14605674, 0.15412536, 0.016466787, -0.059278283, 0.029998286, -0.00068858435, -0.0027129282, 0.0683202],
    ]

    static let anime: [String: [Float]] = [
        "a": [0.31913698, -0.8639814, -0.21908881, -0.19934702, 0.067328036, 0.12217373, -0.14488834, -0.056973446, -0.016414825, -0.12790598, -0.055443708, -0.023390107],
        "i": [-0.1497452, -0.42586112, 0.55979705, -0.58176076, 0.011946491, -0.03556669, -0.2373788, -0.055790216, -0.13766953, -0.10859733, -0.16281696, -0.16209805],
        "u": [0.73192143, -0.5421461, -0.10311874, -0.21410795, -0.12751476, 0.08968319, -0.16355357, -0.18857905, -0.056618918, -0.11037455, -0.10252203, -0.037135284],
        "e": [0.088906564, -0.8507527, 0.22507165, -0.325794, -0.281722, 0.05881834, -0.006942835, -0.04078394, -0.06267491, -0.07382495, -0.038932934, -0.12682268],
        "o": [0.56856555, -0.61125916, -0.2988877, -0.3815423, -0.07988115, 0.18792395, -0.04775577, -0.034831464, -0.0033994264, -0.13748887, -0.059784014, -0.022538256],
    ]
}

extension LipSyncProfile {
    /// Fast path for the common case: a default-config profile for `preset`.
    /// Falls back to `.synthesized(preset:config:)` for any config whose
    /// synthesis-relevant fields differ from `LipSyncConfig.default` —
    /// `minVolumeDb` and `historyLength` do not affect synthesis, so they are
    /// not part of the comparison.
    public static func defaultProfile(preset: LipSyncVoicePreset, config: LipSyncConfig = .default) -> LipSyncProfile {
        guard config.matchesDefaultSynthesisFields else {
            return .synthesized(preset: preset, config: config)
        }
        let references: [String: [Float]]
        switch preset {
        case .standard: references = LipSyncDefaultProfileData.standard
        case .male: references = LipSyncDefaultProfileData.male
        case .female: references = LipSyncDefaultProfileData.female
        case .anime: references = LipSyncDefaultProfileData.anime
        }
        return LipSyncProfile(presetName: preset.rawValue, references: references)
    }
}

private extension LipSyncConfig {
    /// Whether the fields that actually feed vowel synthesis and the MFCC
    /// chain match `LipSyncConfig.default`'s.
    var matchesDefaultSynthesisFields: Bool {
        let reference = LipSyncConfig.default
        return targetSampleRate == reference.targetSampleRate
            && fftSize == reference.fftSize
            && melChannels == reference.melChannels
            && mfccCount == reference.mfccCount
            && melLowHz == reference.melLowHz
            && melHighHz == reference.melHighHz
            && preEmphasis == reference.preEmphasis
    }
}

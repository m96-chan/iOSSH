import Foundation

/// The locales offered for a host, as `LANG` values.
///
/// A locale the host has not installed is not rejected, it is ignored, and the shell carries on
/// in C — where macOS `ls` replaces the bytes of a non-ASCII filename with question marks (#21).
/// A typo fails the same silent way, which is why this is a list rather than a text field.
enum HostLocale {
    /// UTF-8 forms of the languages a host is most likely to have generated. `C.UTF-8` is last
    /// because it is the portable choice rather than anyone's language: most Linux hosts have it
    /// and macOS does not.
    static let choices = [
        "ja_JP.UTF-8",
        "en_US.UTF-8",
        "en_GB.UTF-8",
        "zh_CN.UTF-8",
        "zh_TW.UTF-8",
        "ko_KR.UTF-8",
        "de_DE.UTF-8",
        "fr_FR.UTF-8",
        "es_ES.UTF-8",
        "it_IT.UTF-8",
        "pt_BR.UTF-8",
        "ru_RU.UTF-8",
        "C.UTF-8"
    ]
}

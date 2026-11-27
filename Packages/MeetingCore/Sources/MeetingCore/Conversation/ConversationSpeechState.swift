import Foundation

/// The speech pack state of the face-to-face screen. Unlike the meeting's `speechState`, a
/// model counts as `.installed` only when this app has also reserved its locale: a model the
/// system already had may not be usable unreserved (unverified without a device), and only
/// `installSpeechPack` reserves. That call is idempotent, so offering it costs one tap.
///
/// The lists are `SpeechTranscriber.supportedLocales`, `.installedLocales` and
/// `AssetInventory.reservedLocales`. The reservation looked for is that of the supported
/// match, which is the locale `installSpeechPack` reserves.
func reservedSpeechState(for locale: Locale, supported: [Locale], installed: [Locale],
                         reserved: [Locale]) -> PackState {
    let match = installedLocale(matching: locale, in: supported)
    guard installedLocale(matching: locale, in: installed) != nil else {
        return match == nil ? .unsupported : .notInstalled
    }
    return installedLocale(matching: match ?? locale, in: reserved) == nil ? .notInstalled : .installed
}

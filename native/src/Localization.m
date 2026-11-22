#import <Foundation/Foundation.h>
#import "Localization.h"

#import "LocalizationCatalog.h"

id revivePlexResolveLanguage(id preference, id systemLanguages)
{
    NSArray *supported = @[@"en", @"tr", @"sv", @"es"];
    if ([supported containsObject:preference ?: @""]) return preference;
    NSString *system = [systemLanguages isKindOfClass:[NSArray class]] ? [systemLanguages firstObject] : nil;
    if (![system isKindOfClass:[NSString class]]) return @"en";
    NSString *base = [[system lowercaseString] componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"-_"]].firstObject;
    return [supported containsObject:base ?: @""] ? base : @"en";
}

static NSString *diagnosticLanguage;
void revivePlexSetDiagnosticLanguage(id language)
{
    diagnosticLanguage = [@[@"en", @"tr", @"sv", @"es"] containsObject:language ?: @""] ? [language copy] : nil;
}

id revivePlexLanguage(void)
{
    if (diagnosticLanguage) return diagnosticLanguage;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    return revivePlexResolveLanguage([defaults stringForKey:@"RevivePlexLanguage"], [defaults arrayForKey:@"AppleLanguages"] ?: [NSLocale preferredLanguages]);
}

id revivePlexKeyboardLanguage(void)
{
    NSString *language = [[NSUserDefaults standardUserDefaults] stringForKey:@"RevivePlexKeyboardLanguage"];
    return [@[@"tr", @"en", @"sv", @"es"] containsObject:language ?: @""] ? language : revivePlexLanguage();
}

id revivePlexLanguagePreference(void)
{
    return [[NSUserDefaults standardUserDefaults] stringForKey:@"RevivePlexLanguage"] ?: @"system";
}

signed char revivePlexSetLanguage(id language)
{
    if (![@[@"system", @"tr", @"en", @"sv", @"es"] containsObject:language ?: @""]) return NO;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:language forKey:@"RevivePlexLanguage"];
    return [defaults synchronize];
}

void revivePlexToggleKeyboardLanguage(void)
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSArray *languages = @[@"tr", @"en", @"sv", @"es"];
    NSUInteger index = [languages indexOfObject:revivePlexKeyboardLanguage()] + 1;
    if (index >= languages.count) index = 0;
    [defaults setObject:languages[index] forKey:@"RevivePlexKeyboardLanguage"];
    [defaults synchronize];
}

id revivePlexText(id source)
{
    NSString *language = revivePlexLanguage();
    if ([language isEqual:@"tr"]) return source;
    static NSDictionary *english;
    if (!english) {
        english = @{
            @"Ara":@"Search",
            @"Hakkında":@"About",
            @"Sürüm":@"Version",
            @"Derleme":@"Build",
            @"Topluluk tarafından geliştirilen Plex medya oynatıcısı":@"Community-built Plex media player",
            @"Platform":@"Platform",
            @"Lisans":@"License",
            @"Kaynak kod ve destek":@"Source code and support",
            @"Jailbreak yapılmış Apple TV gerektirir.":@"Requires a jailbroken Apple TV.",
            @"Bağımsız bir projedir; Plex veya Apple ile bağlantılı değildir.":@"Independent project; not affiliated with Plex or Apple.",
            @"Video akışı oynatılamadı. Yeniden deneyebilir veya video kalitesini düşürebilirsin.":@"The video stream could not play. Try again or choose a lower video quality.",
            @"Sunucu videoyu zamanında hazırlayamadı. Daha düşük kaliteyle yeniden deneyebilirsin.":@"The server took too long to prepare the video. Try again with a lower quality.",
            @"Program rehberi":@"Program guide",
            @"Program rehberi bulunamadı":@"No program guide available",
            @"Önceki gün":@"Previous day",
            @"Sonraki gün":@"Next day",
            @"Yayın bulunamadı":@"No programs found",
            @"Bu yayın sona erdi":@"This program has ended",
            @"Kayıt seçeneği bulunamadı":@"No recording options available",
            @"Kaydı planla":@"Schedule recording",
            @"Uygun kayıt kütüphanesi bulunamadı":@"No compatible recording library available",
            @"Kaydın saklanacağı kütüphaneyi seç.":@"Choose the library for this recording.",
            @"Tekrar":@"Repeat",
            @"Tekrar kapalı":@"Repeat off",
            @"Tüm sırayı tekrarla":@"Repeat all",
            @"Bu içeriği tekrarla":@"Repeat one",
            @"Seçimin ardından oynatma kaldığı yerden devam eder.":@"Playback resumes from the current position after your selection.",
            @"Sürüm seç":@"Choose version",
            @"Sırayı düzenle":@"Edit queue",
            @"Sıradan çıkar":@"Remove from queue",
            @"Şimdi oynatılıyor":@"Now playing",
            @"Oynatma sırası":@"Play queue",
            @"Kayıt takvimi":@"Recording schedule",
            @"Kayıt kuralları":@"Recording rules",
            @"Planlanmış kayıt bulunamadı":@"No recordings scheduled",
            @"Kayıt kuralını kaldır":@"Remove recording rule",
            @"Bu kuralın gelecekteki kayıtları iptal edilir. Mevcut kayıt dosyaları korunur. Vazgeçmek için Geri'ye bas.":@"Future recordings for this rule will be cancelled. Existing recording files are kept. Press Back to cancel.",
            @"Canlı TV":@"Live TV",
            @"Kullanılabilir kanal bulunamadı":@"No channels available",
            @"Plex sunucusunda Live TV ve DVR kurulumu yapılmış bir tuner ve etkin kanallar gerekir.":@"Set up a tuner and enable channels in your Plex server's Live TV & DVR settings.",
            @"Keşfet":@"Discover",
            @"Daha fazla":@"More",
            @"S%d B%d":@"S%d E%d",
            @"Plex Home kullanıcıları":@"Plex Home users",
            @"Devam et":@"Continue",
            @"Plex Home PIN kodunu gir":@"Enter your Plex Home PIN",
            @"Altyazı indiriliyor…":@"Downloading subtitle…",
            @"↑ Girişi atla":@"↑ Skip intro",
            @"↑ Jeneriği atla":@"↑ Skip credits",
            @"Oynatma ayarları":@"Playback settings",
            @"Seçenekleri değiştirdikten sonra kaldığın yerden devam et.":@"Change your options, then resume where you paused.",
            @"Çalma listesine ekle":@"Add to playlist",
            @"Bu liste boş. İçerik ayrıntısından yeni öğeler ekleyebilirsin.":@"This playlist is empty. Add items from their details screen.",
            @"İçerikleri düzenle":@"Edit items",
            @"Listeyi düzenle":@"Edit playlist",
            @"Listeyi sil":@"Delete playlist",
            @"Bir yukarı taşı":@"Move up",
            @"Bir aşağı taşı":@"Move down",
            @"Listeden çıkar":@"Remove from playlist",
            @"Yalnızca çalma listesi silinir; kütüphanedeki dosyalar korunur. Vazgeçmek için Geri'ye bas.":@"Only the playlist is deleted; library files are kept. Press Back to cancel.",
            @"Kaydediliyor…":@"Saving…",
            @"Yeni liste":@"New playlist",
            @"Kaydet":@"Save",
            @"Yeniden adlandır":@"Rename",
            @"Liste adını yaz ve Kaydet'i seç.":@"Enter a playlist name, then choose Save.",
            @"Altyazı ara":@"Search subtitles",
            @"Altyazı dili":@"Subtitle language",
            @"Altyazıyı seçerek Plex sunucusuna indir. Ardından altyazı listesinden etkinleştir.":@"Select a subtitle to download it to Plex, then enable it in the subtitle list.",
            @"Çalma listeleri":@"Playlists",
            @"Tümünü oynat":@"Play all",
            @"Karıştır":@"Shuffle",
            @"Listeyi tekrarla":@"Repeat playlist",
            @"Giriş ve jenerik atlama":@"Intro and credits skipping",
            @"Girişi otomatik atla":@"Automatically skip intros",
            @"Jeneriği otomatik atla":@"Automatically skip credits",
            @"Sunucunun sağladığı giriş ve jenerik işaretlerini kullanır.":@"Uses intro and credits markers provided by the server.",
            @"İzleme listesine ekle":@"Add to Watchlist",
            @"İzleme listesinden çıkar":@"Remove from Watchlist",
            @"Bu içerik seçili sunucuda bulunmuyor":@"This title is not available on the selected server",
            @"Sol/sağ: Fotoğraf · Seç: Slayt gösterisini başlat/durdur":@"Left/right: Photo · Select: Start/pause slideshow",
            @"Tür":@"Genre",
            @"Yıl":@"Year",
            @"İzleme durumu":@"Watch status",
            @"Filtreyi temizle":@"Clear filter",
            @"Seçenekler için “Select”i basılı tut":@"Hold “Select” for options",
            @"Uygunsa özgün videoyu koru":@"Preserve compatible video",
            @"Seçilen kalite üst sınırdır. Uyumlu ve sınırın altındaki video özgün çözünürlüğünü korur; gerektiğinde ses veya video dönüştürülür.":@"Quality is an upper limit. Compatible video below it keeps its original resolution; audio or video is converted when needed.",
            @"Filtreleri temizle":@"Clear filters",
            @"Sırala":@"Sort",
            @"Filtrele":@"Filter",
            @"Koleksiyonlar":@"Collections",
            @"Tümü":@"All",
            @"Ada göre A–Z":@"Title A–Z",
            @"Ada göre Z–A":@"Title Z–A",
            @"Yeni eklenenler":@"Recently added",
            @"Yıla göre":@"Year",
            @"Oyuncular ve ekip":@"Cast & Crew",
            @"Açıklamanın tamamı":@"Full description",
            @"Ek içerikler":@"Extras",
            @"Sahneler":@"Chapters",
            @"Sahne":@"Chapter",
            @"Puan ver":@"Rate",
            @"Ayarlar":@"Settings",
            @"Sil":@"Delete",
            @"Boşluk":@"Space",
            @"Ses":@"Audio",
            @"Altyazı":@"Subtitles",
            @"Kapalı":@"Off",
            @"Açık":@"On",
            @"Otomatik sonraki bölüm":@"Autoplay next episode",
            @"Sonraki içeriği otomatik oynat":@"Autoplay next item",
            @"Oynat":@"Play",
            @"Parça":@"Track",
            @"Sonuçlar":@"Results",
            @"Oynatıcı":@"Player",
            @"Plex Kütüphanesi":@"Plex Library",
            @"Plex Oturumu":@"Plex Sign In",
            @"Plex Sunucusu":@"Plex Server",
            @"Plex Bağlantısı":@"Plex Connection",
            @"Plex etkinleştirme":@"Link Plex",
            @"Plex Etkinleştirme":@"Link Plex",
            @"Yükleniyor…":@"Loading…",
            @"Oturum doğrulanıyor…":@"Checking your session…",
            @"İzlemeye devam et":@"Resume",
            @"Baştan oynat":@"Play from beginning",
            @"İzlendi":@"Watched",
            @"İzlenmedi":@"Unwatched",
            @"İzlendi olarak işaretle":@"Mark as watched",
            @"İzlenmedi olarak işaretle":@"Mark as unwatched",
            @"Yeni filmler":@"Recently added movies",
            @"Yeni bölümler":@"Recently added episodes",
            @"Tüm kütüphaneler":@"All libraries",
            @"Kütüphaneler":@"Libraries",
            @"Arama sonuçları":@"Search results",
            @"Aranıyor…":@"Searching…",
            @"Başlık yaz":@"Enter a title",
            @"Film veya dizi adı yaz":@"Search for a movie or show",
            @"Sonuç bulunamadı":@"No results found",
            @"İçerik bulunamadı":@"No content found",
            @"Ayrıntı bulunamadı":@"Details unavailable",
            @"Bağlantı kurulamadı":@"Could not connect",
            @"Oynatma durumu":@"Playback status",
            @"Bu içerik oynatılamıyor":@"This item cannot be played",
            @"Plex bu içerik için oynatılabilir dosya bildirmedi.":@"Plex did not provide a playable file for this item.",
            @"Sunucu durumu":@"Server status",
            @"Sunucu seç":@"Select server",
            @"Plex hesabının erişilebilir sunucusu bulunamadı":@"No accessible server was found for this Plex account",
            @"Sunucuya bağlanılıyor…":@"Connecting to server…",
            @"Video kalitesi":@"Video quality",
            @"Plex sunucusu videoyu seçilen kaliteye ve Apple TV’nin desteklediği biçime dönüştürür.":@"Plex converts video to the selected quality and a format supported by this Apple TV.",
            @"Oturumu kapat":@"Sign out",
            @"Oturumu kapat ve onayla":@"Confirm sign out",
            @"Yalnızca bu Apple TV’deki oturum kapanır.":@"This signs out only this Apple TV.",
            @"Oturum kapatılamadı":@"Could not sign out",
            @"Plex hesabını bağla":@"Link your Plex account",
            @"Kütüphaneyi açmak için önce oturum aç.":@"Sign in to access your library.",
            @"Kod oluştur":@"Get a code",
            @"Kod oluşturmak için seç":@"Select to get a code",
            @"Kodu Plex sayfasına gir.":@"Enter this code on the Plex website.",
            @"Yeni kod oluştur":@"Get a new code",
            @"Yeniden dene":@"Try again",
            @"Telefon onayı bekleniyor…":@"Waiting for you to link your account…",
            @"Telefonunla QR kodu tara veya plex.tv/link adresini aç.":@"Scan the QR code with your phone or visit plex.tv/link.",
            @"Etkinleştirme kodu alınıyor…":@"Getting your sign-in code…",
            @"Plex hesabı bağlandı":@"Plex account linked",
            @"Oturum kaydedilemedi":@"Could not save your session",
            @"Plex sunucu adresi geçersiz":@"Invalid Plex server address",
            @"Plex hesabının bu sunucuya erişimi doğrulanamadı":@"Could not verify access to this Plex server",
            @"Bu oturumun kütüphaneye erişimi yok.":@"This account cannot access the library.",
            @"Sunucu yapılandırması geçersiz.":@"Invalid server configuration.",
            @"Plex yapılandırması geçersiz":@"Invalid Plex configuration",
            @"Plex kimlik doğrulaması gerekli":@"Please sign in to Plex",
            @"Plex bağlantısı kurulamadı":@"Could not connect to Plex",
            @"Plex sunucusu yanıt verdi":@"Plex server is available",
            @"Plex sunucusuna ulaşılamadı.":@"Could not reach the Plex server.",
            @"Kullanılabilir parça yok":@"No tracks available",
            @"Değişiklik kaydedilemedi. Geri dönüp yeniden deneyebilirsin.":@"Could not save the change. Go back and try again.",
            @"Sistem oynatıcısı açılamadı. Geri dönüp yeniden deneyebilirsin.":@"Could not open the system player. Go back and try again.",
            @"Plex sunucusunda hazırlanıyor…":@"Preparing video on your Plex server…",
            @"Plex uyumlu akışı hazırlayamadı. Sunucu bağlantısını ve dönüştürme ayarını kontrol et.":@"Plex could not prepare a compatible stream. Check your server connection and transcoding settings.",
            @"Duraklat / devam et":@"Pause / resume",
            @"15 saniye geri":@"Back 15 seconds",
            @"30 saniye ileri":@"Forward 30 seconds",
            @"Altyazı parçası":@"Subtitle track",
            @"Ses parçası":@"Audio track",
            @"Ekranı doldur / sığdır":@"Fill / fit screen",
            @"Ekranı doldur":@"Fill screen",
            @"Görüntüyü sığdır":@"Fit screen",
            @"Altyazı kapalı":@"Subtitles off",
            @"Gömülü altyazı yok":@"No embedded subtitles",
            @"Ek ses parçası yok":@"No additional audio track",
            @"Duraklatıldı":@"Paused",
            @"Oynatılıyor":@"Playing",
            @"Video kaynağı açılamadı":@"Could not open the video source",
            @"Video alanı hazır değil":@"Video surface is not ready",
            @"Video bitti":@"Playback finished",
            @"Video oynatılamadı":@"Video playback failed",
            @"Kodun süresi doldu":@"This code has expired",
            @"Plex etkinleştirmeyi reddetti":@"Plex could not link this device",
            @"Plex kodu alınamadı (%ld)":@"Could not get a Plex code (%ld)",
            @"Yıl: %@":@"Year: %@",
            @"Süre: %d dk":@"Duration: %d min",
            @"%d dk":@"%d min",
            @"%d bölüm":@"%d episodes",
            @"%@ · S%d B%d":@"%@ · S%d E%d",
            @"S%d B%d · %@":@"S%d E%d · %@",
            @"Uygulama dili":@"App language",
            @"Klavye dili":@"Keyboard language",
            @"Sistem dili":@"System language",
            @"Dil değişikliği ana ekrana döndüğünde uygulanır.":@"The language changes when you return to the home screen."
        };
    }
    NSString *fallback = english[source] ?: source;
    NSArray *translations = additionalTranslations()[fallback];
    if ([language isEqual:@"sv"] && translations.count == 2) return translations[0];
    if ([language isEqual:@"es"] && translations.count == 2) return translations[1];
    return fallback;
}

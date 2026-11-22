typedef enum {
    NoScreen, Home, Movies, Shows, ContinueWatching, Search, Settings,
    FilmDetail, ShowSeasons, SeasonEpisodes, EpisodeDetail, SearchResults, Connection
} Screen;

typedef struct {
    NSString *title;
    Screen destination;
} MenuRow;

typedef struct {
    NSString *title;
    const MenuRow *rows;
    long count;
} MenuScreen;

#define SCREEN(title, rows) {title, rows, sizeof(rows) / sizeof((rows)[0])}

static const MenuRow homeRows[] = {
    {@"Filmler", Movies}, {@"Diziler", Shows}, {@"İzlemeye devam et", ContinueWatching},
    {@"Ara", Search}, {@"Ayarlar", Settings}
};
static const MenuRow movieRows[] = {{@"Kıyı · 2024", FilmDetail}};
static const MenuRow showRows[] = {{@"Gece Hattı · 2025", ShowSeasons}};
static const MenuRow continueRows[] = {
    {@"Kıyı · %42 tamamlandı", FilmDetail}, {@"Gece Hattı · S1 B1 · %18 tamamlandı", EpisodeDetail}
};
static const MenuRow searchRows[] = {{@"Örnek arama: Kıyı", SearchResults}};
static const MenuRow settingsRows[] = {{@"Sunucu bağlantısı", Connection}};
static const MenuRow filmDetailRows[] = {
    {@"2024 · 94 dakika", NoScreen}, {@"İzleme ilerlemesi: %42", NoScreen},
    {@"Bir kıyı kasabasında geçen örnek film.", NoScreen}
};
static const MenuRow seasonsRows[] = {{@"1. Sezon", SeasonEpisodes}};
static const MenuRow episodeRows[] = {{@"1. Bölüm · Son Sefer", EpisodeDetail}};
static const MenuRow episodeDetailRows[] = {
    {@"1. Sezon · 1. Bölüm · 46 dakika", NoScreen}, {@"İzleme ilerlemesi: %18", NoScreen}
};
static const MenuRow connectionRows[] = {
    {@"Veri kaynağı: Örnek kütüphane", NoScreen}, {@"Plex sunucusu bağlı değil", NoScreen}
};

static const MenuScreen mockScreens[] = {
    [Home] = SCREEN(@"RevivePlex · Örnek Kütüphane", homeRows),
    [Movies] = SCREEN(@"Filmler", movieRows),
    [Shows] = SCREEN(@"Diziler", showRows),
    [ContinueWatching] = SCREEN(@"İzlemeye devam et", continueRows),
    [Search] = SCREEN(@"Ara", searchRows),
    [Settings] = SCREEN(@"Ayarlar", settingsRows),
    [FilmDetail] = SCREEN(@"Kıyı", filmDetailRows),
    [ShowSeasons] = SCREEN(@"Gece Hattı", seasonsRows),
    [SeasonEpisodes] = SCREEN(@"1. Sezon", episodeRows),
    [EpisodeDetail] = SCREEN(@"Son Sefer", episodeDetailRows),
    [SearchResults] = SCREEN(@"Arama sonuçları · Kıyı", movieRows),
    [Connection] = SCREEN(@"Sunucu bağlantısı", connectionRows)
};

#undef SCREEN

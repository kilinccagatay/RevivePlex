// Application copy only; Plex-provided library and media titles are never translated.
id revivePlexText(id source);
id revivePlexLanguage(void);
id revivePlexResolveLanguage(id preference, id systemLanguages);
id revivePlexKeyboardLanguage(void);
signed char revivePlexSetLanguage(id language);
void revivePlexToggleKeyboardLanguage(void);
#define RPText(source) revivePlexText(source)

void revivePlexSetDiagnosticLanguage(id language);

id revivePlexLanguagePreference(void);

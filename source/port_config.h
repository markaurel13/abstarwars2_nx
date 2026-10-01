/* port_config.h -- Angry Birds Star Wars II settings for the android32 runtime.
 */
#ifndef PORT_CONFIG_H
#define PORT_CONFIG_H

/* ------------------------------------------------------------------ the game */
#define PORT_TITLE    "Angry Birds Star Wars II"
#define PORT_NAME     "abstarwars2_nx"
#define PORT_PACKAGE  "com.rovio.angrybirdsstarwarsii.ads"
#define PORT_BANNER   "abstarwars2_nx: Angry Birds Star Wars II (Rovio Fusion engine, armeabi-v7a)"
#define PORT_OLD_ROOT_PATHS "/switch/abstarwars2"

/* The APK, by what is in it: it holds the game's library */
#define PORT_APK_DESC "Angry Birds Star Wars II 1.9.25 (com.rovio.angrybirdsstarwarsii.ads, armeabi-v7a)"
#define PORT_APK_ROLES                                                                        \
  {.what = "the game", .need = (const char *const[]){"lib/armeabi-v7a/libAngryBirdsStarWarsII.so", NULL}, \
   .package = "com.rovio.angrybirdsstarwarsii.ads", .version_code = 192500, .flags = RT_APK_PACKAGE_BONUS}
#define PORT_LAUNCHER_START_NOTE "(the first start unpacks the game's library from the APK)"

/* ------------------------------------------------------------------ libc */
#define RT_PROC_COMM "com.rovio.angry" /* /proc/self/stat's comm */

/* ------------------------------------------------------------------ files */
#define RT_MIGRATE_MOVE_NEWER_NRO 1

/* ------------------------------------------------------------------ input */
#define RT_PAD_MAX_PLAYERS 1

#endif

/* abs_setup_plan.c -- Angry Birds Star Wars II setup plan for dcr_setup.c */
#include "dcr_setup.h"

static const char *const k_libs[] = {"libAngryBirdsStarWarsII.so"};

const RtSetupPlan port_setup_plan = {
    .libs = k_libs,
    .nlibs = 1,
    .libs_what = "Unpacking the game",
    .apk_requirement = "This port needs Angry Birds Star Wars II (com.rovio.angrybirdsstarwarsii.ads,\n"
                       "armeabi-v7a): use the APK of that version.",
    .libs_p0 = 100,
    .libs_p1 = 500,
    .classes_p0 = 550,
    .classes_p1 = 950,
};

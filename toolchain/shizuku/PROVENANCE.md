# Shizuku client API (vendored)

`shizuku.jar` is the merged `classes.jar` of the four official **Shizuku 13.1.5**
client artifacts:

| AAR | sha256 |
|---|---|
| api-13.1.5.aar | `4def9bde498ef8626614c2fc5db9af4749c86f16f6c33e3f5658d35e70bab59b` |
| aidl-13.1.5.aar | `33fe7191cdd69fcb66d649264f3b0c47acb2f3d6343afc05b98dbbff6f221963` |
| provider-13.1.5.aar | `b0f18cd9812464ec171c53cac93a819fe411718a3965c311f01eb4de265381b3` |
| shared-13.1.5.aar | `4659642c9339be0a26e9c65bb8648f7ad6d8f4a465f557993ccbc78802381635` |

Source: Maven Central `dev.rikka.shizuku:{api,aidl,provider,shared}:13.1.5` (not
reachable from this sandbox), taken from the committed `app/libs/` of
`github.com/Ritel-T/SamsungRegionOverride`, whose `*.sha256` files match the
values above. The upstream sources are `github.com/RikkaApps/Shizuku-API`.

`shizuku.jar` sha256: `72584d81daeb71164153ed20cfea4e948c7a58563ce7cfe2864e47a3b23579cb`
(37 classes, pure Java - no Kotlin runtime needed).

Rebuild: extract `classes.jar` from each AAR and merge the `.class` entries
(no duplicates), keeping the `proguard.txt` of each AAR empty as shipped.

## The manifest payload the jar cannot carry

An AAR is classes **plus a manifest**, and Gradle merges that manifest into
every consuming app. `classes.jar` alone silently drops these entries - which
is exactly how vc9-vc11 shipped a Shizuku integration that could never work
(the status row stuck on "not running", restarting Shizuku changing nothing).
Both live in `provider-13.1.5.aar`'s `AndroidManifest.xml` upstream and are
now declared by hand in `app/src/main/AndroidManifest.xml`, pinned by
`ShizukuWiringTest`:

| entry | why the app is dead without it |
|---|---|
| `<uses-permission android:name="moe.shizuku.manager.permission.API_V23"/>` | the server's `BinderSender` pushes the binder **only** to packages whose `requestedPermissions` contains this name; that push (into `ShizukuProvider.call("sendBinder")`) is the single way a client ever receives a binder |
| `<meta-data android:name="moe.shizuku.client.V3_SUPPORT" android:value="true"/>` | the server's `getApplications()` and the manager's `AuthorizationManager` filter on it - without it the app cannot appear in (or be granted from) Shizuku's own UI |

The `ShizukuProvider` declaration itself (authority `<applicationId>.shizuku`,
`exported=true`, `multiprocess=false`, guarded by `INTERACT_ACROSS_USERS_FULL`)
is written in the app manifest for the same reason: aapt2 does not substitute
`${applicationId}`, and there is no manifest merger here at all.

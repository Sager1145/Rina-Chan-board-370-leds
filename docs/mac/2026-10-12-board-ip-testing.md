# Board-specific hotspot IP batch — 2026-10-12

The user's acceptance requirements are distinct factory hotspot addresses on the two production boards, BLE address discovery, manual address changes, shared Mac/iPad UI, and real multiboard testing. Testing follows a batch workflow: inspect and test broadly, collect defects, fix the batch, then repeat acceptance. No commits or external publishing are part of this work.

## Collected defects and fixes

| Defect | Repair |
| --- | --- |
| Every board used the same fixed AP gateway | Derive a private gateway from board ID on first boot and persist `rinawifi.apip`; both boards use the same production binary |
| App hotspot dials used a fixed gateway | Read reported AP address over BLE; persist it separately from Home Wi-Fi IP; dial the selected physical board |
| AP selection did not associate the selected board | Join the exact selected SSID; release the previous AP carrier only after association succeeds; retain BLE/Home Wi-Fi siblings |
| Same customized SSID could bypass conflict checks or overwrite a sibling record | Prefer known physical identity; use only an unambiguous legacy SSID fallback |
| Cold legacy saved addresses survived firmware upgrade | One factory-address retry after a genuine failure of a legacy gateway, across direct, saved, and carrier-selection paths; explicit overrides retain priority |
| IP-only edits could discard hotspot credentials | Empty credential fields with an explicit IP change only the address |
| Cross-subnet edits and factory reset could leave old client leases | Detach/restart the AP when its gateway changes, then recreate a DHCP pool excluding the gateway; keep BLE available |
| Generic App command rejection hid firmware's reason | Preserve command context and append nonempty firmware error details; missing/empty reasons retain the old fallback |

The default policy is injective for distinct final 24-bit board-ID suffixes. Full IDs sharing that suffix can share a default; manufacturing should verify the reported values and use manual overrides when needed. DHCP leases never include the configured gateway, `.0`, or `.255`.

## Software and deployment evidence

- Strict ASan/UBSan address policy and six production-translation-unit integration cases: passed. `/tmp/rina-unique-ip-host-tests-final.log`.
- Existing 19 firmware repair regressions: passed. `/tmp/rina-unique-ip-repair-tests.log`.
- Protocol, persistence/stress findings, and face identity host runners: passed. `/tmp/rina-unique-ip-other-host-tests-final.log`.
- RinaCore: 376 tests, 11 opt-in skips, zero failures. `/tmp/rina-unique-ip-core-final-tests.log`.
- Initial Mac full run: 685 tests, three opt-in skips, one failure exposed discarded firmware error details. Final full repeat: 686 tests, three opt-in skips, zero failures. `/tmp/rina-unique-ip-mac-regressions-verified.log`.
- Shared iPad build and final incremental error-detail build passed. `/tmp/rina-unique-ip-ipad-build-verified.log`.
- Production firmware build passed. SHA256: `04dfc7dd9678e50db1098524279135a7996e97705af99b9dd3d239f86f2c88bf`.
- Both ESP32 app partitions flashed at `0x10000`, write hashes verified. NVS and filesystem preserved; fresh NVS/OTA backups saved before deployment.
- Actual serial boot/status confirms A `80B54EF48E09` → `10.244.142.9`, B `80B54EF74801` → `10.247.72.1`, manual saved face 7 of 11, 34 lit LEDs, brightness 50, color `#f971d4`, interval 3000 ms, `refreshFail=0` on both.

Grok independently reviewed the pure address mapping, validation, and DHCP pool math; no defects found. A separate Codex integration review found the identity, legacy recovery, and factory-reset gaps listed above; they were repaired before final acceptance.

## Real Mac/board test sequence

1. Connect both boards inside the Mac app over BLE. Read factory AP IPs and separate Home Wi-Fi fields; confirm blank test Wi-Fi credentials.
2. Join A's hotspot in the app. Send actual faces/controls/text and observe serial state and at least 60 seconds of connection stability.
3. Exercise A.AP + B.BLE group control and text playback; switch to B.AP + A.BLE and repeat. A Mac has one Wi-Fi association, so two concurrent SoftAP carriers are not an acceptance claim.
4. Repeatedly switch selected boards/carriers; verify exactly two physical board records, commands reach the intended board, and surviving BLE/group sessions remain usable.
5. Over BLE, reject an invalid/public/reserved gateway and a sibling's IP; change A to `10.31.41.1`, preserve its SSID/password, reboot, and confirm the override through serial/BLE.
6. Join the edited A hotspot in the app and send real data. Restore A's factory IP over BLE; reconnect and repeat sends.
7. Restore original board settings/output, remove only the test-created group, restore the Mac's original network, disconnect the app from both boards, verify no board OS Bluetooth pairings, and close our serial captures.

Physical acceptance results will be recorded after executing the sequence; serial boot verification alone is not a claim that hotspot stability passed.

## Scroll FPS, rapid sends, and shared reorder follow-up

- Shared Mac software batch: 695 tests, four hardware opt-in skips, zero failures (`/tmp/rina-scroll-motion-stress-full-verified.log`).
- Real two-board BLE stress: one opt-in test passed in 311.110 seconds (`/tmp/rina-scroll-real-board-high-intensity.log`). Includes 40 target switches with ten acknowledged sends per selection (200 frames per board), mirror/stitched frame bursts, single/mirror/stitched scroll at 1/10/20/60 requested FPS, coalesced parameter changes, pause/step/resume, and a 34-second stitched run crossing periodic reanchor. This is actual board traffic, not preview-only testing.
- Physical measured rates at 1/10/20 FPS closely matched their targets. Requested 60 FPS uses a 17 ms interval: the 34-second window measured A 58.8167 FPS and B 58.8219 FPS, with 108 latency-corrected phase samples.
- Hardware test restored both complete face sets, names, original runtime settings, and AP-only settings; reboot/readback and terminal disconnect passed. OS Bluetooth board pairings: zero (`/tmp/rina-scroll-stress-pairings.log`). Subsequent UI tests reconnect the boards, so final UI cleanup is still required.
- Current diagnostic production firmware on both boards: SHA256 `c42824a2c8673517f749a993a32234503c89e149266f9aa650834a5f79390f81`. Both app-partition uploads verified their flash hashes. Diagnostic additions expose actual presentation timing and TCP send failure reasons; they do not change the transport deadline policy.
- Shared preview uses live insertion ordering, stable physical-board IDs, direct pointer tracking, and an interruptible spring for neighbouring boards. No wiggle is added. Reduced Motion suppresses positional spring animation. Drag cancellation restores the local order; release commits one insertion operation.
- Paused reorder previously restarted playback. The shared coordinator now preserves the held frame, pending FPS, and loop settings, including asynchronous preparation failure. All 76 coordinator regressions passed (`/tmp/rina-paused-reorder-tests.log`); shared iPad build passed (`/tmp/rina-paused-reorder-ipad-build.log`).
- Runtime held-drag animation is still unverified: the native automation drag cannot supply the required initial 0.25-second long press. Its non-activation is not counted as a gesture defect. Accessibility movement and source review do not establish visual motion quality.

### Native hotspot limitation still under investigation

A and B report distinct factory addresses over BLE. A manual `10.31.41.1` override survived reboot and was restored to `10.244.142.9`; invalid/public and sibling-conflicting addresses were rejected in the Mac app. Exactly two physical board rows remain while carriers change.

An earlier native B hotspot association obtained `10.247.72.32` on the correct interface, but TCP disconnected after roughly 5–10 seconds. After the real BLE stress cleanup/reboots, current native exact/prefix scans fail before association; macOS Wi-Fi settings also show no board SSIDs. These are distinct observations. Native hotspot stability and edited-IP association are not marked passed. The Mac remains on its original BELL456 network during these failed scan attempts. Local firmware/SDK diagnosis continues; no causal firmware fix is asserted without fresh evidence.

### Latest native UI evidence

The installed app completed 50 coordinate-based tab switches across all five tabs in 24.950 seconds during real two-board stitched playback. Both boards remained playing, the 36-character draft persisted, and configured FPS remained 60. Native accessibility insertion reordered the physical IDs while idle. A subsequent paused insertion kept both boards paused at the same held global frame 273, verified independently through serial; however, the old reciprocal-rate reconstruction changed reported/requested 60 to 59 while preserving the 17 ms physical interval. This new defect was collected and repaired by retaining the exact current requested FPS, including live edits and reconnect replay, with capability clamping retained.

Board B's real Wi-Fi scan over BLE found A's broadcasting hotspot at -34 dBm, along with the test/home networks. Bluetooth and AP status remained available after the scan. This disproves absent A beacons as a sufficient explanation for the current Mac discovery failure. RinaBoard's macOS Location Services switch was verified on without changing it. Exact native A association still returned no matching Wi-Fi; system Wi-Fi discovery still omitted both board SSIDs. No speculative firmware repair was made for this observation.

### Final shared reorder build and batch cleanup

All 78 group coordinator tests passed after the exact-FPS follow-up (`/tmp/rina-exact-fps-reorder-tests.log`), including unchanged 60 FPS requests, 10-to-60 live edits, paused reconnect/reorder, and valid versus incompatible adoption metadata. Final shared iPad and signed Mac Release builds passed (`/tmp/rina-exact-fps-ipad-build.log`, `/tmp/rina-exact-fps-mac-release.log`); the Mac build script installed and verified the app signature.

The test-created Rina Batch Test group was removed through the app; both saved physical rows showed Not connected before the app was quit. Final direct serial checks rebooted on serial-open and independently verified both boards: manual/idle, no active scroll or timeline frames, saved face 7 of 11, 34 lit LEDs, brightness 50, color #f971d4, interval 3000 ms, original factory AP IPs, and refreshFail=0. Logs: `/tmp/rina-final-state-80B54EF48E09.log`, `/tmp/rina-final-state-80B54EF74801.log`. Both serial ports are closed; the timed diagnostic capture exited normally. Final OS Bluetooth board pairing count is zero (`/tmp/rina-final-board-pairings.log`). Mac original BELL456 association was confirmed in System Settings with en0 192.168.2.117. No new home network credentials were provisioned during this batch.

Remaining acceptance gaps are the actual initial long-press drag motion on iPad and native Mac hotspot discovery/stability. The final exact-FPS follow-up has software regression/build evidence; the previous real paused-reorder test established held-frame/state preservation and exposed the now-fixed 60-to-59 metadata issue, rather than being claimed as a physical rerun of the final exact-FPS fix.

## Continued acceptance requested after initial report

The user explicitly authorized native XCUITest long-press gesture execution, restricted to app UI, and confirmed allowing the macOS Wi-Fi API prompt. Native B hotspot association then obtained 10.247.72.32; the en0 route to 10.247.72.1 was correct. New serial diagnostics identified repeated partially sent EV_POWER/EV_STATUS frames hitting the unchanged 250 ms deadline with errno 11 while the socket remained connected. The Mac IPv4 watch stayed in the board subnet during these failures. A subscribe-disabled Python probe timed out during TCP connect and a five-packet ICMP probe received no replies; CLI process privacy remains a possible confound, so these do not independently prove RF loss. Four sparse CCMP replay rejection lines were observed, insufficient to establish a cause.

A new on-demand STATUS diagnostic exposes actual driver mode/AP started state/IP/channel, AP config hidden/beacon interval, peer MAC/RSSI, inactivity and power-save getters, return codes, and internal minimum free/largest block. It does not alter radio settings. Production diagnostic image SHA256 `8150a2cad34d1c359e57426fe1f7bd3017456210c6826418a3b0a30975f4f670` was built and flashed identically on both ESP32s; both write hashes verified. Initial live state on B: AP started, correct10.247.72.1, broadcastSSID, primary1/secondaryabove, beacon100TU, inactivity300s, zero peers before association, internalFree67660/largest31732. This rules out a normal300-second AP inactivity expiry as an explanation for10–17-second failures.

The isolated native UI-only XCTest runner built successfully. Its first execution failed before any test case or gesture: “Timed out while enabling automation mode.” Apple automationmodetool reports Automation Mode disabled and user authentication required; Developer mode is disabled. A normal Xcode Product→Test request was also made. The user was asked to handle normal local authentication; no authentication exemption or protected-system-dialog automation was attempted. The current real app remains on Rina Drag Test, both boards over BLE, paused at60 requested/configured FPS; no held-drag success is claimed yet. A packet-header capture filtered to the two board TCP addresses was requested from the user because sudo requires their local password.

Temporary native bridge scan diagnostics have been added while diagnosing the discovery distinction. The current Mac error includes scan/activation counts for diagnosis; these temporary implementation details must be removed before final acceptance. No causal discovery/stability repair or two-board hotspot pass is claimed at this stage.

### Continued acceptance: packet evidence and focused fixes (19:35)

- User handled system prompts. Native Xcode then ran the test but initially skipped it because TestAction inherited LaunchAction environment. Fixed the scheme to use its own explicit opt-in environment. The next run reached the test and skipped because the native AX observer lacked Accessibility permission; no held gesture has passed yet. Idle Automation Mode being disabled is expected after a test, so the script no longer blocks normal authenticated Xcode testing on that idle status.
- User started the restricted 160-packet TCP header capture. `/tmp/rina-ap-tcp-headers.pcap` completed with 160 packets (12322 bytes). Mac receive windows remained 65535 while the board retransmitted data already ACKed by the Mac and did not advance ACKs for repeated upstream commands. This establishes the direction of the initiating stall, but host capture cannot prove over-air delivery.
- Added bounded full-scan fallback after an empty directed CoreWLAN scan; exact selected SSID filtering remains in the native bridge. All 11 MacWiFiAdapterTests passed, including loading the embedded native bridge. Real discovery remains under investigation: a later exact and broadcast attempt both reported absence.
- Fixed Add Board's stale success text by consulting live connected hotspot sessions; unrelated connected BLE boards do not count. All 3 lifecycle regression tests passed. Mac Release built and signed successfully, installed for retest.
- A-only diagnostic firmware changes one variable: explicitly `esp_wifi_set_ps(WIFI_PS_NONE)` after AP startup. Arduino's AP-only `setSleep(false)` previously changed a cached value without changing the live driver. Flash verified, binary SHA256 `f6f796832a42b26fd97b78e43ff7c79f8c30e7e5f5ba3f144a3bc96b0277a303`; serial shows return0 and ps0. B retains the prior image and ps1. This is an experiment, not an accepted production fix; sustained actual Mac-app hotspot control is still required.
- Adding the native runner via macOS27 Device Control and Data Access was rejected by automatic approval review because the explicit prior permission covered Accessibility, not the displayed broader permission. Requested scope-specific approval; no entry was added or bypassed.

### Native held-drag acceptance and negative power-save experiment (19:48)

- User explicitly approved the displayed macOS27 Device Control and Data Access scope for `/tmp/rina-drag-native-build/Build/Products/Debug/RinaBoardUITests-Runner.app`, temporarily. Added via normal authenticated System Settings UI and verified switch ON. Remove this test-only entry after the final gesture retest.
- Native test `/tmp/rina-native-held-drag-authorized.xcresult`: 1 passed, 0 failed, 0 skipped in55.141seconds. Forward/reverse genuine0.4secondlongpress+continuousdrag+2secondheld endpoint, no-move held release, and short drag before activation all passed. Exported 7attachments to `/tmp/rina-native-held-drag-evidence`. CSV descriptions now correctly quoted. Forward79samples/72mousedown, reverse81/73; each has6distinct neighbour positions whilemousedown (global centre1835.015..2469.11), with successive intermediatepositions rather than only endpoints. Both serial logs preservepaused244/frameCount339/interval17/uiFps60 throughreorders.
- Actual screenshots exposed a separate display defect: paused reorder preparation briefly hides the bitmap/FPS before new uploads complete, while physicalboards retainpaused244. This is being repaired and will require a focused retest.
- A ps0experiment did NOT resolveTCPstall: actualapp-associatedA10.244.142.32,RSSI-35,receivedsubscribe/getinfo/brightness/color/interval,thenrepeatedpartialeventdeadlinefailures. LivewidthalreadyHT20afterassociation (secondaryChannel0); do not acceptPSNONE or20MHz alone as the TCPfix.
- A-only scratchdiagnostic firmware supports temporarySDK ps/bw/phycontrols, preservingsecurity,SSID,IP,channel,NVS. NextcontrolledexperimentchangesAP802.11ncapability only (bgvsbgn) to distinguishaggregationinteroperability; removeharnessbeforefinalfirmware.
- CoreWLANfullscaninitiallyreturned5readable5GHznetworkswithoutboards. SystemSettingsWi-Filistinitiallyalsoomittedboards; openingitthenanappfullscanlaterfoundAandawaitednormalmacOSassociationconfirmation. Do not claim discovery fullystableyet.

### Updated user scope: local Wi-Fi and reconnection controls

The user explicitly stopped Mac hotspot testing: test the boards' own Wi-Fi scanning and connection, Bluetooth, local-only Wi-Fi and board AP modes. No Internet requirement and no Mac hotspot creation. Mac was restored to BELL456 via normal System Settings; Ethernet remains unchanged. Native board-hotspot TCP experiments are stopped, not marked passed. Both ps0 and bg-only experiments reproduced failures; remove scratch setters and restore clean firmware on both boards.

The user added automatic same-board carrier fallback, immediate retry and stopping automatic retries. Implementation plan: `docs/superpowers/plans/2026-10-12-local-board-reconnection.md`. Shared BoardConnection owns cancellation and a bounded loop; BoardSession supplies Bluetooth/local-STA alternatives while preserving physical identity. No automatic Mac SSID association is part of fallback. Interface policy tests (hotspot Wi-Fi only, home Wi-Fi unrestricted) passed2/2, but this was not accepted as the complete hotspot TCP fix. A supplemental en0-bound BSD minimal TCP probe timed out; do not claim the old unbound probe alone established routing as cause.

Paused reorder preview retention passed79coordinator tests in21.547seconds. Final shipping build and physical held-drag retest remain after reconnect changes are integrated.

### Local-only batch verification (20:15–20:25)

- Both boards scanned the selected test network themselves through the Mac app, provisioned via Bluetooth, and connected locally: A `192.168.0.227`, B `192.168.0.104`. Mac remained on its existing BELL456 Wi-Fi plus Ethernet; no Mac hotspot or Internet reachability check was used.
- Final shared Mac software suite: `/tmp/rina-local-reconnect-full-software-tests.log`, 719 tests, 1 skipped, 0 failures. Mac Release `/tmp/rina-local-reconnect-release-build.log` and iPad Simulator `/tmp/rina-local-reconnect-ipad-build.log` both BUILD SUCCEEDED. Installed signed Release at the existing app path; temporary native scan-count error diagnostics removed.
- Both local TCP carriers completed actual app handshakes. A and B both received a339-frame stitched bitmap,9clock samples each, then synchronized group_start at17ms/configured60FPS; serial confirms commands and group starts.
- Removed embedded web setup phone-hotspot card, JavaScript submission, DOM references and translations; legacy compatibility handlers retained. Host regression checks Node syntax, all4languages, scan/select/provisioning/AP/mode flows and passes. Final binarySHA256 `28225e1766f88bcd668f35aa2abda163b95685e0a38b0fdcc4b39b6b2b2bd11e`; both final uploads succeeded with flash hashes verified (`/tmp/rina-local-only-final-A-upload.log`, B counterpart). NVS preserved.
- Actual automatic same-board localTCP→Bluetooth fallback observed on A during its flash, while B stayed onlocalTCP. After Bflash/restart, B recovered overBLE while A recovered overlocalTCP. No duplicate physical board rows. A group send during the unavailable flash interval correctly reported notconnected rather than false success; subsequent sends remain to be checked after recovery.
- Held A temporarily inROMbootloader using read-only esptool read-mac/no-reset (no flash/NVS writes), leaving Bonline. On pendingAconnection, Stopautomaticretry immediately showed Notconnected + automaticretrystopped. ImmediateRetry while Aremained unavailable failed once with timeout and retained the stopped state; B remained Online. Normal Areset follows to check no spontaneous resumption and explicit recovery.

- After normal A restart and local HTTP reachability on both boards, A remained stopped; clicking ImmediateRetry restored localTCP. The independent final review found group reconciliation could clear a stopped latch when another same-identity alias wasconnected. Repaired automatic reset to preserve explicitly stopped retries; new duplicate-session/peer-drop/explicitresume regression included in18 GroupAutoConnectorTests, all passed (`/tmp/rina-stop-alias-regression-tests.log`). Final Mac Release and shared iPad build passed after this correction.
- Real mixed-carrier held-drag retest `/tmp/rina-local-mixed-held-drag-preview.xcresult`:1passed,0failed,0skipped,54.584seconds. Forward66samples/56held/5distinctneighbourpositions; reverse79/72/6. Both retainphysical paused zero-basedframe239 of339,17ms,uiFPS60 andrefreshFail0 afterforward/reverse/no-move/cancel. CUA app screenshot confirms retained visiblebitmaps,requested/configured60FPS andFrame240/339 after thetest. XCTest's screenshotattachments incorrectly captured the other display; do not use those PNGs as appvisualevidence. NativeAX CSV plus test assertions andseparate CUA screenshot are valid. Retention acrossstalledpreparation iscovered by79coordinatorregressions; end-state screenshot alone doesnotprove everyintermediatepixel.
- Read thefinalflashedsetupHTMLfrombothSTAIPs locally:14643byteseach, generic `scan()`button present, no hssid orsetHotspotsubmission. HTTPcheckdoesnotrequireInternet.

### Final installed app stress and newly discovered clear-network defect

Final app build/signature verified and installed. Six consecutive Random+Send group actions delivered new frames to bothboards; lastframe37lit onboth,refreshFail0. Fasttabsequence Text→Speak→Live→Faces→Settings→Text→Faces preserved twoonlineparticipants andSynced. These complement the earlier400ackframes/40targetswitches/allscrollrates test, not a replacement claim for everyfeature. Heldnative CSV evidence copied into `docs/mac/evidence/2026-10-12-held-drag-forward.csv` and reversecounterpart.

Clearing B's testWiFi through actual localTCP uncovered anotherfirmwarebug: receivedwifi_clear_credentials seq137 at376981ms, then immediatecarrierdisconnection preventedtype129reply at377002ms. Appreportedtimeout although boardclearedcredentials andfellbackBLE. This is not a pass; firmware reply-before-radiochange repair and two-boardTCPclear retest arepending.

Temporaryrunnerpermissionremoval requested throughnormalSystemSettings. CurrentTouchIDauthentication ispending. Automaticapprovalreview rejected switchingbacktoRinaBoardUI while thatauthentication remainedpending; noindirectUIworkaround attempted. Sourcebuild/debugwork continues.

### Reply-order repair: two physical-board acceptance

- Final Wi-Fi reply build `/tmp/rina-wifi-reply-final-firmware-build.log` succeeded; both uploads hashverified. BinarySHA256 `666a00643374a0c4f99a5941d2b5d2d0e3cd65bcb97c46f097f883a2bfd84af2`. Actual B localTCPwifi_clear_credentials seq192 at73538ms, drivereraseat73689ms, disconnect73704ms; noerrorpopup. A samecommandseq212 at300047ms, erase300170ms, disconnect300185ms; noerrorpopup. Both recoveredviaBLE, profilesemptyandSTAIPblank.
- Both restoredAPonly and independentlyscannedthetestSSID whileBLEremainedusable. MacstillBELL456; noMachotspotcreated. TemporaryRinaDragTestgroupdeleted. RunnerbroadscopepermissionconfirmedOFFandentryremoved; pairedBoardCount0 (`/tmp/rina-local-final-pairing-check.log`).
- Added row-scoped retry/stop menus afterreview: groupprimarypromotionisintentional,butcurrentboardheaderalonehidretrycontrolsoftheofflinepeer. Menuactionsdirectlycapturethatrowconnectionwithoutselection. SharedMacandiPadbuildspassed;realrowcontrolretestpending.
- Supplementaloldharness initiallyfailedfromarchived-directorylayout; reranfromitsdocumentedfirmware-relativelocation. Itthenbuiltbutreported155PASS14FAIL. ReviewedF1oversized/truncatedcarriercontract,F2totalelapseddeadline,F3latestonlydepthandtargetJSONcapacity: tenexpectations/modelswereoutdatedandarebeingcorrectedwithstrictmeaningfulassertions. FourF6synthetic17ms-overloadcasesexposereallegacylocal-scrollphase loss, distinctfromphysicalrenderbudgetlimits. Productionphasecorrection+newfaultregressionsandactualFPSretestarepending. Do notclaimoldrawrunpassed.

### Final batch verification before hardware stress

- Final sharedcode suite `/tmp/rina-local-cold-final-software-tests.log`:724tests,1hardware-optinskip,0failures,145.669seconds. Cold savedTCP failure uses pinnedsavedidentity forsame-boardBLEfallback; alternatehandshake muststillverifyidentity beforeconnected. Unknown/newtargets cannotborrowpriorboardidentity. FinalMacReleaseandsharediPadSimulatorbuilds succeeded.
- Repairedarchivedoracles nowall7harnesses complete:172PASS,0CASEfailures at100000seededfuzziterations (`/tmp/rina-local-scroll-final-host-stress.log`). Oversizedframes assertERR413+close+newcarrierrecovery, truncatedpayloadno-phantom-PING, fuzz separatesexpectedclosefromtrueoverflow; BLEtotalframe-deadlineandlatest-onlyqueue testsassertcurrentcontracts; capacitymodelusesactualsavedfacesfunctionplusactualparsefixtures. Original155PASS14FAIL evidence preserved. F6 retains6oldphysical-reference shortfalls as explicitmeasurements; new14phase/no-burstacceptancechecksPASS. Thisdoesnotprove60physicalFPSundertheover-budgetmodels.
- Legacyphasefaulttests failedbeforeimplementationandpasswithASAN/UBSANafter:stall,nonloopfinalframe,pause/resume,zeroanchor,intervalchange,uint32wrap; existinggroupend/loop unchanged. Broad27production-TU regressioncasesallPASS afterupdatingfallbackoracle toframe2aftertwo100msintervals,actualLED2pixelsandexactly1refresh. Newprotocolparagraphdocuments logicalskipvsactualpresentations. Finalfirmwarebuildsuccess26.305seconds,SHA256 `a5de335f5359e57a122f40455f1ad96fe320892fd6dc3fd59e1a0876912a6fee`. Finaltwo-boardflashandrealallratebursttestpending.
- Usercompletedpermissionauthentication; runnerentryremoved. AtestAPMacprofiledeletedthroughnormalForgetconfirmation. BtestprofilecleanuphitrepeatednativeCUAwindowerror-10005; useraskedtofinishonlyBrecord. OriginalBELL456andCialloprofilesremain.

### Final installed release and physical row-control retest

FinalSHA256 `a5de335f5359e57a122f40455f1ad96fe320892fd6dc3fd59e1a0876912a6fee` flashedandhashverifiedonbothboards(A21.816s,B22.039s). Serialboots:APonly/wifiMode2,distinctoriginalAPIPs,manual/idle,face7/11,brightness50,color#f971d4,34lit,refreshFail0. NohomeWiFimemoryrecreated. FinalsignedMacReleaseinstalled;freshstartupwithsavedunreachablehomeWiFiAautomaticallyrecoveredBLEAwithoutmanualcarrierselection. SavedB'sunreachableWiFialsoautomaticallyrecoveredBLEB; bothphysicalrowsOnline.

HeldonlyAinROMbootloaderusingread-onlyMACquery,Bstayedcurrentandconnected. FromA'sownMoremenuStopautomaticretry showedstoppedstatusandRetrynowentry,whilecurrentboardheaderremainedB. AfterA'snormalreset,itremainedNotconnecteduntilArowRetrynowwasclicked; finalhandshakeverificationpendingnextobservation. Thischecksrowcapturethroughasynchronousoperation,notonlypresenceofmenuitems.

### 2026-10-13: bounded manual retry fixes

Manual retry now tries the original carrier followed by same-board alternatives, bounded to five candidates. A stopped automatic loop stays stopped. Stopping or superseding a manual attempt invalidates its epoch and transport session, preventing late readiness from publishing a connection.

Independent review identified a lost-alternate bug: carrier teardown clears the Wi-Fi snapshot, so rebuilding candidates during manual retry could lose the local station address learned over Bluetooth. The new snapshot-dependent regression failed before the fix (`/tmp/rina-manual-cached-alternate-red.log`, three failed assertions). Manual retry now retains candidates learned before teardown, filters by physical identity, and removes repeated transport objects. The regression passes after this change.

Verification: `/tmp/rina-manual-fallback-final-software-tests.log` completed 729 tests, one opt-in hardware test skipped, zero failures in 143.019 seconds. This includes failed Wi-Fi to Bluetooth fallback, retained Bluetooth to Wi-Fi fallback, rejected wrong-board identity, stopped retries and superseded manual attempts. Mac Release and iPad Simulator builds both succeeded (`/tmp/rina-manual-fallback-final-release-build.log`, `/tmp/rina-manual-fallback-final-ipad-build.log`). Installed the signed release at `/Users/sager/Applications/RinaBoard-Mac/RinaBoard.app`; strict deep signature verification passed. The app remains closed.

Hardware retest remains pending: both previously recorded USB serial ports are currently absent; `/dev/cu.*` lists only Bluetooth-Incoming-Port and debug-console. Serial capture could not open either board and exited. Asked the user to reconnect both ESP32s. No new flash or real-board stress pass is claimed for this continuation. The already-flashed firmware hash above remains the last verified firmware. Per-board menu retry, final firmware scrolling/FPS stress, and verification of B's remaining Mac test-AP profile cleanup remain outstanding.

### 2026-10-13: software-only optimization scope

The user changed the continuation to code optimization only. Physical testing and flashing are paused; no board or system-network actions were performed in this optimization pass.

Manual retry candidate selection now deduplicates Wi-Fi addresses and ports across fresh and cached transport objects, including the original Wi-Fi endpoint. This prevents duplicate objects targeting the same unavailable endpoint from consuming the five-attempt budget and excluding a later usable address. Selection uses one explicit pass and stops after four alternate candidates; Bluetooth/AP transports retain object-based deduplication rather than incorrectly treating all carriers of one kind as the same endpoint.

The new disconnected-state regression failed before optimization (`/tmp/rina-retry-dedup-red.log`). An intermediate lazy-filter implementation failed related tests because collection traversal reevaluated the stateful predicate; it was replaced with the explicit single pass. Final verification: `/tmp/rina-retry-dedup-final-tests.log`, 58 reconnect, session, saved-recovery and group-auto-connect tests passed with zero failures in 6.005 seconds. The Mac test target built and ran; the shared iPad Simulator build succeeded (`/tmp/rina-retry-dedup-final-ipad-build.log`). No runtime speedup measurement is claimed. This pass changes source only; the previously installed Release predates this endpoint deduplication optimization.

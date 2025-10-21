default	10:47:15.083651+0800	WonderWhisper Mac	LSExceptions shared instance invalidated for timeout.
default	10:47:23.816237+0800	runningboardd	Acquiring assertion targeting [app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>:79189] from originator [osservice<com.apple.coreservices.launchservicesd>:367] with description <RBSAssertionDescriptor| "frontmost:79189" ID:402-367-63030 target:79189 attributes:[
	<RBSDomainAttribute| domain:"com.apple.launchservicesd" name:"RoleUserInteractiveFocal" sourceEnvironment:"(null)">
	]>
default	10:47:23.816293+0800	runningboardd	Assertion 402-367-63030 (target:[app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>:79189]) will be created as active
default	10:47:23.816405+0800	WindowServer	0[outside of RPC]: [DeferringManager] Updating policy {
    advicePolicy: .frontmost;
    frontmostProcess: 0x0-0x234234 (WonderWhisper Mac) mainConnectionID: 17520F;
} for reason: updated frontmost process
default	10:47:23.816456+0800	WindowServer	0[outside of RPC]: [DeferringManager] Deferring events from frontmost process PSN 0x0-0x234234 (WonderWhisper Mac) -> <pid: 79189>
default	10:47:23.816512+0800	WindowServer	new deferring rules for pid:397: [
    [397-A06]; <keyboardFocus; WonderWhisper Mac:0x0-0x234234>; () -> <pid: 79189>; reason: frontmost PSN --> outbound target,
    [397-A05]; <keyboardFocus; <frontmost>>; () -> <token: WonderWhisper Mac:0x0-0x234234; pid: 397>; reason: frontmost PSN,
    [397-A04]; <keyboardFocus>; () -> <token: <frontmost>; pid: 397>; reason: Deferring to <frontmost>
]
default	10:47:23.816529+0800	WindowServer	[keyboardFocus 0xa4aceabc0] setRules:forPID(397): [
    [397-A06]; <keyboardFocus; WonderWhisper Mac:0x0-0x234234>; () -> <pid: 79189>; reason: frontmost PSN --> outbound target,
    [397-A05]; <keyboardFocus; <frontmost>>; () -> <token: WonderWhisper Mac:0x0-0x234234; pid: 397>; reason: frontmost PSN,
    [397-A04]; <keyboardFocus>; () -> <token: <frontmost>; pid: 397>; reason: Deferring to <frontmost>
]
default	10:47:23.816688+0800	runningboardd	[app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>:79189] Ignoring jetsam update because this process is not memory-managed
default	10:47:23.816747+0800	runningboardd	[app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>:79189] Ignoring suspend because this process is not lifecycle managed
default	10:47:23.816800+0800	runningboardd	[app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>:79189] Set darwin role to: UserInteractiveFocal
default	10:47:23.816842+0800	runningboardd	[app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>:79189] Ignoring GPU update because this process is not GPU managed
default	10:47:23.818661+0800	WindowServer	chain did update (setDeferringRules) <keyboardFocus; display: null> containsEndOfChain: YES; [
    <token: <frontmost>; pid: 397>,
    <token: WonderWhisper Mac:0x0-0x234234; pid: 397>,
    <pid: 79189>,
    <token: viewbridge-key-window; pid: 79189>
]
default	10:47:23.816953+0800	runningboardd	[app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>:79189] Ignoring memory limit update because this process is not memory-managed
default	10:47:23.821115+0800	runningboardd	Acquiring assertion targeting [app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>:79189] from originator [osservice<com.apple.coreservices.launchservicesd>:367] with description <RBSAssertionDescriptor| "notification:79189" ID:402-367-63031 target:79189 attributes:[
	<RBSDomainAttribute| domain:"com.apple.launchservicesd" name:"LSNotification" sourceEnvironment:"(null)">
	]>
default	10:47:23.821219+0800	runningboardd	Assertion 402-367-63031 (target:[app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>:79189]) will be created as active
default	10:47:23.826565+0800	runningboardd	Calculated state for app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>: running-active (role: UserInteractiveFocal) (endowments: <private>)
default	10:47:23.826816+0800	runningboardd	Acquiring assertion targeting [app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>:79189] from originator [osservice<com.apple.WindowServer(88)>:397] with description <RBSAssertionDescriptor| "FUSBFrontmostProcess" ID:402-397-63032 target:79189 attributes:[
	<RBSDomainAttribute| domain:"com.apple.fuseboard" name:"Frontmost" sourceEnvironment:"(null)">,
	<RBSAcquisitionCompletionAttribute| policy:AfterApplication>
	]>
default	10:47:23.826867+0800	runningboardd	Assertion 402-397-63032 (target:[app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>:79189]) will be created as active
default	10:47:23.826869+0800	runningboardd	[app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>:79189] Ignoring jetsam update because this process is not memory-managed
default	10:47:23.826934+0800	runningboardd	[app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>:79189] Ignoring suspend because this process is not lifecycle managed
default	10:47:23.827029+0800	runningboardd	[app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>:79189] Ignoring GPU update because this process is not GPU managed
default	10:47:23.827182+0800	runningboardd	[app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>:79189] Ignoring memory limit update because this process is not memory-managed
default	10:47:23.827244+0800	ControlCenter	Received state update for 79189 (app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>, running-active-NotVisible
default	10:47:23.827542+0800	gamepolicyd	Received state update for 79189 (app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>, running-active-NotVisible
default	10:47:23.834470+0800	runningboardd	Calculated state for app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>: running-active (role: UserInteractiveFocal) (endowments: <private>)
default	10:47:23.834777+0800	runningboardd	[app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>:79189] Ignoring jetsam update because this process is not memory-managed
default	10:47:23.834822+0800	runningboardd	[app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>:79189] Ignoring suspend because this process is not lifecycle managed
default	10:47:23.834868+0800	runningboardd	[app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>:79189] Ignoring GPU update because this process is not GPU managed
default	10:47:23.834955+0800	gamepolicyd	Received state update for 79189 (app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>, running-active-NotVisible
default	10:47:23.834965+0800	ControlCenter	Received state update for 79189 (app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>, running-active-NotVisible
default	10:47:23.834935+0800	runningboardd	[app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>:79189] Ignoring memory limit update because this process is not memory-managed
default	10:47:23.840282+0800	runningboardd	Calculated state for app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>: running-active (role: UserInteractiveFocal) (endowments: <private>)
default	10:47:23.840904+0800	ControlCenter	Received state update for 79189 (app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>, running-active-NotVisible
default	10:47:23.840930+0800	gamepolicyd	Received state update for 79189 (app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>, running-active-NotVisible
default	10:47:23.842323+0800	kernel	Sandbox: ContextStoreAgent(77621) allow file-read-data /Users/danekapoor/Library/Developer/Xcode/DerivedData/WonderWhisper_Mac-etopzasemmdxcbcnjiilnrcrnhlh/Build/Products/Debug/WonderWhisper Mac.app
default	10:47:23.842634+0800	kernel	Sandbox: ContextStoreAgent(77621) allow file-read-data /Users/danekapoor/Library/Developer/Xcode/DerivedData/WonderWhisper_Mac-etopzasemmdxcbcnjiilnrcrnhlh/Build/Products/Debug/WonderWhisper Mac.app/Contents
default	10:47:23.842914+0800	kernel	Sandbox: ContextStoreAgent(77621) allow file-read-data /Users/danekapoor/Library/Developer/Xcode/DerivedData/WonderWhisper_Mac-etopzasemmdxcbcnjiilnrcrnhlh/Build/Products/Debug/WonderWhisper Mac.app/Contents/Info.plist
default	10:47:23.844186+0800	kernel	Sandbox: ContextStoreAgent(77621) allow file-read-data /Users/danekapoor/Library/Developer/Xcode/DerivedData/WonderWhisper_Mac-etopzasemmdxcbcnjiilnrcrnhlh/Build/Products/Debug/WonderWhisper Mac.app
default	10:47:23.847258+0800	kernel	Sandbox: ContextStoreAgent(77621) allow file-read-data /Users/danekapoor/Library/Developer/Xcode/DerivedData/WonderWhisper_Mac-etopzasemmdxcbcnjiilnrcrnhlh/Build/Products/Debug/WonderWhisper Mac.app/Contents/MacOS/WonderWhisper Mac
default	10:47:23.847692+0800	kernel	1 duplicate report for Sandbox: ContextStoreAgent(77621) allow file-read-data /Users/danekapoor/Library/Developer/Xcode/DerivedData/WonderWhisper_Mac-etopzasemmdxcbcnjiilnrcrnhlh/Build/Products/Debug/WonderWhisper Mac.app/Contents/MacOS/WonderWhisper Mac
default	10:47:23.847700+0800	kernel	Sandbox: ContextStoreAgent(77621) allow file-read-xattr /Users/danekapoor/Library/Developer/Xcode/DerivedData/WonderWhisper_Mac-etopzasemmdxcbcnjiilnrcrnhlh/Build/Products/Debug/WonderWhisper Mac.app/Contents/MacOS/WonderWhisper Mac
default	10:47:23.851382+0800	kernel	Sandbox: ContextStoreAgent(77621) allow file-read-data /Users/danekapoor/Library/Developer/Xcode/DerivedData/WonderWhisper_Mac-etopzasemmdxcbcnjiilnrcrnhlh/Build/Products/Debug/WonderWhisper Mac.app/Contents/Info.plist
default	10:47:26.018760+0800	WonderWhisper Mac	[C1.1.1 openrouter.ai:443 ready resolver (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @22.121s, uuid: 0ABE351D-56A8-48F7-B8E6-45506F6F5B8B
default	10:47:26.018771+0800	WonderWhisper Mac	[C1.1 openrouter.ai:443 ready transform (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @22.121s, uuid: E8E27228-FD53-4675-B9D6-F597C00C6E8F
default	10:47:26.018812+0800	WonderWhisper Mac	[C1 104.18.2.115:443 ready parent-flow (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @22.121s, uuid: E8E27228-FD53-4675-B9D6-F597C00C6E8F
default	10:47:26.023956+0800	WonderWhisper Mac	[C4.1.1 openrouter.ai:443 ready resolver (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @22.125s, uuid: 10121CE9-0CDF-4147-B4BA-13D417F2E7AE
default	10:47:26.024025+0800	WonderWhisper Mac	[C4.1 openrouter.ai:443 ready transform (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @22.125s, uuid: B989386A-5239-4A20-BA92-759A132ED866
default	10:47:26.024821+0800	WonderWhisper Mac	[C4 104.18.2.115:443 ready parent-flow (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @22.126s, uuid: B989386A-5239-4A20-BA92-759A132ED866
default	10:47:26.049609+0800	WonderWhisper Mac	[C2.1.1 openrouter.ai:443 ready resolver (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @22.151s, uuid: 1A3C5FC8-100F-4E27-B3F8-EF87CEB71FF7
default	10:47:26.050489+0800	WonderWhisper Mac	[C2.1 openrouter.ai:443 ready transform (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @22.152s, uuid: D6614809-6EAD-4FDE-997E-932372B36779
default	10:47:26.051028+0800	WonderWhisper Mac	[C2 104.18.2.115:443 ready parent-flow (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @22.152s, uuid: D6614809-6EAD-4FDE-997E-932372B36779
default	10:47:26.054173+0800	WonderWhisper Mac	[C5.1 api.groq.com:443 ready transform (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @21.352s, uuid: 1C54BC3F-FE96-4231-862E-B446DE17E31C
default	10:47:26.054512+0800	WonderWhisper Mac	[C5 172.64.147.158:443 ready parent-flow (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @21.353s, uuid: 1C54BC3F-FE96-4231-862E-B446DE17E31C
default	10:47:26.065176+0800	WonderWhisper Mac	[C3.1.1 openrouter.ai:443 ready resolver (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @22.166s, uuid: 28D57649-2D79-49EE-88EE-5FE235B1A969
default	10:47:26.065593+0800	WonderWhisper Mac	[C3.1 openrouter.ai:443 ready transform (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @22.167s, uuid: F97FC3BD-6C56-4E97-8E06-F0F3A905C27C
default	10:47:26.065789+0800	WonderWhisper Mac	[C3 104.18.2.115:443 ready parent-flow (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @22.167s, uuid: F97FC3BD-6C56-4E97-8E06-F0F3A905C27C
default	10:47:26.069757+0800	WonderWhisper Mac	[C5.1.1 api.groq.com:443 ready resolver (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @21.368s, uuid: 535F198C-BD26-4341-AC98-EDE0E1D6A154
default	10:47:26.069827+0800	WonderWhisper Mac	[C5.1 api.groq.com:443 ready transform (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @21.368s, uuid: 1C54BC3F-FE96-4231-862E-B446DE17E31C
default	10:47:26.069886+0800	WonderWhisper Mac	[C5 172.64.147.158:443 ready parent-flow (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @21.368s, uuid: 1C54BC3F-FE96-4231-862E-B446DE17E31C
default	10:47:26.070389+0800	WonderWhisper Mac	[C7.1 api.groq.com:443 ready transform (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @21.223s, uuid: 5CD300BA-7C0E-43A6-9DE6-B2B19387BEC0
default	10:47:26.070421+0800	WonderWhisper Mac	[C7 172.64.147.158:443 ready parent-flow (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @21.223s, uuid: 5CD300BA-7C0E-43A6-9DE6-B2B19387BEC0
default	10:47:26.070873+0800	WonderWhisper Mac	[C6.1.1 api.groq.com:443 ready resolver (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @21.224s, uuid: 6BD073B5-E4E9-48AD-8B30-0A4F45A99638
default	10:47:26.070945+0800	WonderWhisper Mac	[C6.1 api.groq.com:443 ready transform (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @21.224s, uuid: FF68B771-2901-4B50-839C-00C79E160E10
default	10:47:26.070972+0800	WonderWhisper Mac	[C6 172.64.147.158:443 ready parent-flow (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @21.224s, uuid: FF68B771-2901-4B50-839C-00C79E160E10
default	10:47:26.074506+0800	WonderWhisper Mac	[C7.1.1 api.groq.com:443 ready resolver (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @21.227s, uuid: 96BE68F0-0C8D-461D-977C-9F9FDCE091BF
default	10:47:26.074542+0800	WonderWhisper Mac	[C7.1 api.groq.com:443 ready transform (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @21.227s, uuid: 5CD300BA-7C0E-43A6-9DE6-B2B19387BEC0
default	10:47:26.074595+0800	WonderWhisper Mac	[C7 172.64.147.158:443 ready parent-flow (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @21.227s, uuid: 5CD300BA-7C0E-43A6-9DE6-B2B19387BEC0
default	10:47:26.077002+0800	WonderWhisper Mac	[C4.1 openrouter.ai:443 ready transform (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @22.178s, uuid: B989386A-5239-4A20-BA92-759A132ED866
default	10:47:26.077037+0800	WonderWhisper Mac	[C4 104.18.2.115:443 ready parent-flow (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @22.178s, uuid: B989386A-5239-4A20-BA92-759A132ED866
default	10:47:26.077601+0800	WonderWhisper Mac	[C8.1.1 api.groq.com:443 ready resolver (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @21.229s, uuid: CDA35C99-A1F8-43FB-85C8-ABE2C8B820BF
default	10:47:26.077662+0800	WonderWhisper Mac	[C8.1 api.groq.com:443 ready transform (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @21.229s, uuid: F2EF87DD-94EA-4237-A46C-34E899AF54C3
default	10:47:26.077672+0800	WonderWhisper Mac	[C8 172.64.147.158:443 ready parent-flow (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @21.229s, uuid: F2EF87DD-94EA-4237-A46C-34E899AF54C3
default	10:47:26.077904+0800	WonderWhisper Mac	[C2.1 openrouter.ai:443 ready transform (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @22.179s, uuid: D6614809-6EAD-4FDE-997E-932372B36779
default	10:47:26.077975+0800	WonderWhisper Mac	[C2 104.18.2.115:443 ready parent-flow (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @22.179s, uuid: D6614809-6EAD-4FDE-997E-932372B36779
default	10:47:26.078233+0800	WonderWhisper Mac	[C1.1 openrouter.ai:443 ready transform (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @22.180s, uuid: E8E27228-FD53-4675-B9D6-F597C00C6E8F
default	10:47:26.078242+0800	WonderWhisper Mac	[C1 104.18.2.115:443 ready parent-flow (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @22.180s, uuid: E8E27228-FD53-4675-B9D6-F597C00C6E8F
default	10:47:26.078666+0800	WonderWhisper Mac	[C8.1 api.groq.com:443 ready transform (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @21.230s, uuid: F2EF87DD-94EA-4237-A46C-34E899AF54C3
default	10:47:26.078697+0800	WonderWhisper Mac	[C8 172.64.147.158:443 ready parent-flow (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @21.230s, uuid: F2EF87DD-94EA-4237-A46C-34E899AF54C3
default	10:47:26.079026+0800	WonderWhisper Mac	[C3.1 openrouter.ai:443 ready transform (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @22.180s, uuid: F97FC3BD-6C56-4E97-8E06-F0F3A905C27C
default	10:47:26.079039+0800	WonderWhisper Mac	[C3 104.18.2.115:443 ready parent-flow (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @22.180s, uuid: F97FC3BD-6C56-4E97-8E06-F0F3A905C27C
default	10:47:26.079981+0800	WonderWhisper Mac	[C6.1 api.groq.com:443 ready transform (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @21.233s, uuid: FF68B771-2901-4B50-839C-00C79E160E10
default	10:47:26.079986+0800	WonderWhisper Mac	[C6 172.64.147.158:443 ready parent-flow (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @21.233s, uuid: FF68B771-2901-4B50-839C-00C79E160E10
default	10:47:28.617923+0800	runningboardd	Invalidating assertion 402-367-63030 (target:[app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>:79189]) from originator [osservice<com.apple.coreservices.launchservicesd>:367]
default	10:47:28.625870+0800	runningboardd	Invalidating assertion 402-397-63032 (target:[app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>:79189]) from originator [osservice<com.apple.WindowServer(88)>:397]
default	10:47:28.736138+0800	runningboardd	[app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>:79189] Ignoring jetsam update because this process is not memory-managed
default	10:47:28.736356+0800	runningboardd	[app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>:79189] Ignoring suspend because this process is not lifecycle managed
default	10:47:28.736538+0800	runningboardd	[app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>:79189] Set darwin role to: UserInteractiveNonFocal
default	10:47:28.736615+0800	runningboardd	[app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>:79189] Ignoring GPU update because this process is not GPU managed
default	10:47:28.736838+0800	runningboardd	[app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>:79189] Ignoring memory limit update because this process is not memory-managed
default	10:47:28.744908+0800	runningboardd	Calculated state for app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>: running-active (role: UserInteractiveNonFocal) (endowments: <private>)
default	10:47:28.748189+0800	ControlCenter	Received state update for 79189 (app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>, running-active-NotVisible
default	10:47:28.826492+0800	gamepolicyd	Received state update for 79189 (app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>, running-active-NotVisible
default	10:47:28.845371+0800	runningboardd	Assertion did invalidate due to timeout: 402-367-63031 (target:[app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>:79189])
default	10:47:28.947396+0800	runningboardd	[app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>:79189] Ignoring jetsam update because this process is not memory-managed
default	10:47:28.947417+0800	runningboardd	[app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>:79189] Ignoring suspend because this process is not lifecycle managed
default	10:47:28.947549+0800	runningboardd	[app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>:79189] Ignoring GPU update because this process is not GPU managed
default	10:47:28.947662+0800	runningboardd	[app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>:79189] Ignoring memory limit update because this process is not memory-managed
default	10:47:28.955271+0800	runningboardd	Calculated state for app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>: running-active (role: UserInteractiveNonFocal) (endowments: <private>)
default	10:47:28.955780+0800	ControlCenter	Received state update for 79189 (app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>, running-active-NotVisible
default	10:47:28.958290+0800	gamepolicyd	Received state update for 79189 (app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>, running-active-NotVisible
default	10:47:34.123059+0800	WonderWhisper Mac	[C1.1.1 openrouter.ai:443 ready resolver (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @30.225s, uuid: 0ABE351D-56A8-48F7-B8E6-45506F6F5B8B
default	10:47:34.123070+0800	WonderWhisper Mac	[C1.1 openrouter.ai:443 ready transform (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @30.225s, uuid: E8E27228-FD53-4675-B9D6-F597C00C6E8F
default	10:47:34.123075+0800	WonderWhisper Mac	[C1 104.18.2.115:443 ready parent-flow (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @30.225s, uuid: E8E27228-FD53-4675-B9D6-F597C00C6E8F
default	10:47:34.123150+0800	WonderWhisper Mac	[C4.1.1 openrouter.ai:443 ready resolver (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @30.224s, uuid: 10121CE9-0CDF-4147-B4BA-13D417F2E7AE
default	10:47:34.123159+0800	WonderWhisper Mac	[C4.1 openrouter.ai:443 ready transform (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @30.224s, uuid: B989386A-5239-4A20-BA92-759A132ED866
default	10:47:34.123163+0800	WonderWhisper Mac	[C4 104.18.2.115:443 ready parent-flow (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @30.224s, uuid: B989386A-5239-4A20-BA92-759A132ED866
default	10:47:34.123256+0800	WonderWhisper Mac	[C2.1.1 openrouter.ai:443 ready resolver (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @30.224s, uuid: 1A3C5FC8-100F-4E27-B3F8-EF87CEB71FF7
default	10:47:34.123267+0800	WonderWhisper Mac	[C2.1 openrouter.ai:443 ready transform (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @30.224s, uuid: D6614809-6EAD-4FDE-997E-932372B36779
default	10:47:34.123274+0800	WonderWhisper Mac	[C2 104.18.2.115:443 ready parent-flow (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @30.224s, uuid: D6614809-6EAD-4FDE-997E-932372B36779
default	10:47:34.123361+0800	WonderWhisper Mac	[C5.1 api.groq.com:443 ready transform (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @29.421s, uuid: 1C54BC3F-FE96-4231-862E-B446DE17E31C
default	10:47:34.123364+0800	WonderWhisper Mac	[C5 172.64.147.158:443 ready parent-flow (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @29.421s, uuid: 1C54BC3F-FE96-4231-862E-B446DE17E31C
default	10:47:34.123531+0800	WonderWhisper Mac	[C3.1.1 openrouter.ai:443 ready resolver (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @30.224s, uuid: 28D57649-2D79-49EE-88EE-5FE235B1A969
default	10:47:34.123538+0800	WonderWhisper Mac	[C3.1 openrouter.ai:443 ready transform (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @30.224s, uuid: F97FC3BD-6C56-4E97-8E06-F0F3A905C27C
default	10:47:34.123542+0800	WonderWhisper Mac	[C3 104.18.2.115:443 ready parent-flow (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @30.224s, uuid: F97FC3BD-6C56-4E97-8E06-F0F3A905C27C
default	10:47:34.124032+0800	WonderWhisper Mac	[C5.1.1 api.groq.com:443 ready resolver (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @29.422s, uuid: 535F198C-BD26-4341-AC98-EDE0E1D6A154
default	10:47:34.124041+0800	WonderWhisper Mac	[C5.1 api.groq.com:443 ready transform (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @29.422s, uuid: 1C54BC3F-FE96-4231-862E-B446DE17E31C
default	10:47:34.124044+0800	WonderWhisper Mac	[C5 172.64.147.158:443 ready parent-flow (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @29.422s, uuid: 1C54BC3F-FE96-4231-862E-B446DE17E31C
default	10:47:34.124114+0800	WonderWhisper Mac	[C7.1 api.groq.com:443 ready transform (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @29.276s, uuid: 5CD300BA-7C0E-43A6-9DE6-B2B19387BEC0
default	10:47:34.124121+0800	WonderWhisper Mac	[C7 172.64.147.158:443 ready parent-flow (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @29.276s, uuid: 5CD300BA-7C0E-43A6-9DE6-B2B19387BEC0
default	10:47:34.124177+0800	WonderWhisper Mac	[C6.1.1 api.groq.com:443 ready resolver (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @29.278s, uuid: 6BD073B5-E4E9-48AD-8B30-0A4F45A99638
default	10:47:34.124185+0800	WonderWhisper Mac	[C6.1 api.groq.com:443 ready transform (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @29.278s, uuid: FF68B771-2901-4B50-839C-00C79E160E10
default	10:47:34.124188+0800	WonderWhisper Mac	[C6 172.64.147.158:443 ready parent-flow (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @29.278s, uuid: FF68B771-2901-4B50-839C-00C79E160E10
default	10:47:34.135358+0800	WonderWhisper Mac	[C7.1.1 api.groq.com:443 ready resolver (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @29.288s, uuid: 96BE68F0-0C8D-461D-977C-9F9FDCE091BF
default	10:47:34.135385+0800	WonderWhisper Mac	[C7.1 api.groq.com:443 ready transform (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @29.288s, uuid: 5CD300BA-7C0E-43A6-9DE6-B2B19387BEC0
default	10:47:34.135402+0800	WonderWhisper Mac	[C7 172.64.147.158:443 ready parent-flow (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @29.288s, uuid: 5CD300BA-7C0E-43A6-9DE6-B2B19387BEC0
default	10:47:34.137147+0800	WonderWhisper Mac	[C4.1 openrouter.ai:443 ready transform (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @30.238s, uuid: B989386A-5239-4A20-BA92-759A132ED866
default	10:47:34.137206+0800	WonderWhisper Mac	[C4 104.18.2.115:443 ready parent-flow (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @30.238s, uuid: B989386A-5239-4A20-BA92-759A132ED866
default	10:47:34.137659+0800	WonderWhisper Mac	[C8.1.1 api.groq.com:443 ready resolver (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @29.289s, uuid: CDA35C99-A1F8-43FB-85C8-ABE2C8B820BF
default	10:47:34.137742+0800	WonderWhisper Mac	[C8.1 api.groq.com:443 ready transform (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @29.289s, uuid: F2EF87DD-94EA-4237-A46C-34E899AF54C3
default	10:47:34.137763+0800	WonderWhisper Mac	[C8 172.64.147.158:443 ready parent-flow (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @29.289s, uuid: F2EF87DD-94EA-4237-A46C-34E899AF54C3
default	10:47:34.138111+0800	WonderWhisper Mac	[C2.1 openrouter.ai:443 ready transform (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @30.239s, uuid: D6614809-6EAD-4FDE-997E-932372B36779
default	10:47:34.138169+0800	WonderWhisper Mac	[C2 104.18.2.115:443 ready parent-flow (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @30.239s, uuid: D6614809-6EAD-4FDE-997E-932372B36779
default	10:47:34.138508+0800	WonderWhisper Mac	[C1.1 openrouter.ai:443 ready transform (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @30.241s, uuid: E8E27228-FD53-4675-B9D6-F597C00C6E8F
default	10:47:34.138535+0800	WonderWhisper Mac	[C1 104.18.2.115:443 ready parent-flow (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @30.241s, uuid: E8E27228-FD53-4675-B9D6-F597C00C6E8F
default	10:47:34.139260+0800	WonderWhisper Mac	[C8.1 api.groq.com:443 ready transform (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @29.290s, uuid: F2EF87DD-94EA-4237-A46C-34E899AF54C3
default	10:47:34.139298+0800	WonderWhisper Mac	[C8 172.64.147.158:443 ready parent-flow (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @29.290s, uuid: F2EF87DD-94EA-4237-A46C-34E899AF54C3
default	10:47:34.139683+0800	WonderWhisper Mac	[C3.1 openrouter.ai:443 ready transform (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @30.241s, uuid: F97FC3BD-6C56-4E97-8E06-F0F3A905C27C
default	10:47:34.139741+0800	WonderWhisper Mac	[C3 104.18.2.115:443 ready parent-flow (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @30.241s, uuid: F97FC3BD-6C56-4E97-8E06-F0F3A905C27C
default	10:47:34.142303+0800	WonderWhisper Mac	[C6.1 api.groq.com:443 ready transform (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @29.296s, uuid: FF68B771-2901-4B50-839C-00C79E160E10
default	10:47:34.142357+0800	WonderWhisper Mac	[C6 172.64.147.158:443 ready parent-flow (satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi, LQM: good)] event: path:satisfied_change @29.296s, uuid: FF68B771-2901-4B50-839C-00C79E160E10
default	10:47:34.686199+0800	runningboardd	Acquiring assertion targeting [app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>:79189] from originator [osservice<com.apple.coreservices.launchservicesd>:367] with description <RBSAssertionDescriptor| "frontmost:79189" ID:402-367-63073 target:79189 attributes:[
	<RBSDomainAttribute| domain:"com.apple.launchservicesd" name:"RoleUserInteractiveFocal" sourceEnvironment:"(null)">
	]>
default	10:47:34.686263+0800	runningboardd	Assertion 402-367-63073 (target:[app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>:79189]) will be created as active
default	10:47:34.686455+0800	WindowServer	0[outside of RPC]: [DeferringManager] Updating policy {
    advicePolicy: .frontmost;
    frontmostProcess: 0x0-0x234234 (WonderWhisper Mac) mainConnectionID: 17520F;
} for reason: updated frontmost process
default	10:47:34.686523+0800	runningboardd	[app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>:79189] Ignoring jetsam update because this process is not memory-managed
default	10:47:34.686502+0800	WindowServer	0[outside of RPC]: [DeferringManager] Deferring events from frontmost process PSN 0x0-0x234234 (WonderWhisper Mac) -> <pid: 79189>
default	10:47:34.686533+0800	runningboardd	[app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>:79189] Ignoring suspend because this process is not lifecycle managed
default	10:47:34.686556+0800	WindowServer	new deferring rules for pid:397: [
    [397-A0C]; <keyboardFocus; WonderWhisper Mac:0x0-0x234234>; () -> <pid: 79189>; reason: frontmost PSN --> outbound target,
    [397-A0B]; <keyboardFocus; <frontmost>>; () -> <token: WonderWhisper Mac:0x0-0x234234; pid: 397>; reason: frontmost PSN,
    [397-A0A]; <keyboardFocus>; () -> <token: <frontmost>; pid: 397>; reason: Deferring to <frontmost>
]
default	10:47:34.686599+0800	WindowServer	[keyboardFocus 0xa4aceabc0] setRules:forPID(397): [
    [397-A0C]; <keyboardFocus; WonderWhisper Mac:0x0-0x234234>; () -> <pid: 79189>; reason: frontmost PSN --> outbound target,
    [397-A0B]; <keyboardFocus; <frontmost>>; () -> <token: WonderWhisper Mac:0x0-0x234234; pid: 397>; reason: frontmost PSN,
    [397-A0A]; <keyboardFocus>; () -> <token: <frontmost>; pid: 397>; reason: Deferring to <frontmost>
]
default	10:47:34.688086+0800	WindowServer	chain did update (setDeferringRules) <keyboardFocus; display: null> containsEndOfChain: YES; [
    <token: <frontmost>; pid: 397>,
    <token: WonderWhisper Mac:0x0-0x234234; pid: 397>,
    <pid: 79189>,
    <token: viewbridge-key-window; pid: 79189>
]
default	10:47:34.686552+0800	runningboardd	[app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>:79189] Set darwin role to: UserInteractiveFocal
default	10:47:34.686608+0800	runningboardd	[app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>:79189] Ignoring GPU update because this process is not GPU managed
default	10:47:34.686754+0800	runningboardd	[app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>:79189] Ignoring memory limit update because this process is not memory-managed
default	10:47:34.689548+0800	runningboardd	Acquiring assertion targeting [app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>:79189] from originator [osservice<com.apple.WindowServer(88)>:397] with description <RBSAssertionDescriptor| "FUSBFrontmostProcess" ID:402-397-63074 target:79189 attributes:[
	<RBSDomainAttribute| domain:"com.apple.fuseboard" name:"Frontmost" sourceEnvironment:"(null)">,
	<RBSAcquisitionCompletionAttribute| policy:AfterApplication>
	]>
default	10:47:34.689584+0800	runningboardd	Assertion 402-397-63074 (target:[app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>:79189]) will be created as active
default	10:47:34.695662+0800	runningboardd	Calculated state for app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>: running-active (role: UserInteractiveFocal) (endowments: <private>)
default	10:47:34.695980+0800	runningboardd	[app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>:79189] Ignoring jetsam update because this process is not memory-managed
default	10:47:34.696006+0800	runningboardd	Acquiring assertion targeting [app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>:79189] from originator [osservice<com.apple.coreservices.launchservicesd>:367] with description <RBSAssertionDescriptor| "notification:79189" ID:402-367-63075 target:79189 attributes:[
	<RBSDomainAttribute| domain:"com.apple.launchservicesd" name:"LSNotification" sourceEnvironment:"(null)">
	]>
default	10:47:34.696042+0800	runningboardd	[app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>:79189] Ignoring suspend because this process is not lifecycle managed
default	10:47:34.697490+0800	runningboardd	[app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>:79189] Ignoring GPU update because this process is not GPU managed
default	10:47:34.697518+0800	runningboardd	[app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>:79189] Ignoring memory limit update because this process is not memory-managed
default	10:47:34.697551+0800	runningboardd	Assertion 402-367-63075 (target:[app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>:79189]) will be created as active
default	10:47:34.697633+0800	ControlCenter	Received state update for 79189 (app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>, running-active-NotVisible
default	10:47:34.697990+0800	gamepolicyd	Received state update for 79189 (app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>, running-active-NotVisible
default	10:47:34.700546+0800	kernel	Sandbox: ContextStoreAgent(77621) allow file-read-data /Users/danekapoor/Library/Developer/Xcode/DerivedData/WonderWhisper_Mac-etopzasemmdxcbcnjiilnrcrnhlh/Build/Products/Debug/WonderWhisper Mac.app
default	10:47:34.700781+0800	kernel	Sandbox: ContextStoreAgent(77621) allow file-read-data /Users/danekapoor/Library/Developer/Xcode/DerivedData/WonderWhisper_Mac-etopzasemmdxcbcnjiilnrcrnhlh/Build/Products/Debug/WonderWhisper Mac.app/Contents
default	10:47:34.700988+0800	kernel	Sandbox: ContextStoreAgent(77621) allow file-read-data /Users/danekapoor/Library/Developer/Xcode/DerivedData/WonderWhisper_Mac-etopzasemmdxcbcnjiilnrcrnhlh/Build/Products/Debug/WonderWhisper Mac.app/Contents/Info.plist
default	10:47:34.702909+0800	kernel	Sandbox: ContextStoreAgent(77621) allow file-read-data /Users/danekapoor/Library/Developer/Xcode/DerivedData/WonderWhisper_Mac-etopzasemmdxcbcnjiilnrcrnhlh/Build/Products/Debug/WonderWhisper Mac.app
default	10:47:34.703165+0800	runningboardd	Calculated state for app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>: running-active (role: UserInteractiveFocal) (endowments: <private>)
default	10:47:34.704077+0800	runningboardd	[app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>:79189] Ignoring jetsam update because this process is not memory-managed
default	10:47:34.704118+0800	runningboardd	[app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>:79189] Ignoring suspend because this process is not lifecycle managed
default	10:47:34.704147+0800	runningboardd	[app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>:79189] Ignoring GPU update because this process is not GPU managed
default	10:47:34.704202+0800	runningboardd	[app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>:79189] Ignoring memory limit update because this process is not memory-managed
default	10:47:34.708319+0800	kernel	Sandbox: ContextStoreAgent(77621) allow file-read-data /Users/danekapoor/Library/Developer/Xcode/DerivedData/WonderWhisper_Mac-etopzasemmdxcbcnjiilnrcrnhlh/Build/Products/Debug/WonderWhisper Mac.app/Contents/MacOS/WonderWhisper Mac
default	10:47:34.709048+0800	kernel	1 duplicate report for Sandbox: ContextStoreAgent(77621) allow file-read-data /Users/danekapoor/Library/Developer/Xcode/DerivedData/WonderWhisper_Mac-etopzasemmdxcbcnjiilnrcrnhlh/Build/Products/Debug/WonderWhisper Mac.app/Contents/MacOS/WonderWhisper Mac
default	10:47:34.709054+0800	kernel	Sandbox: ContextStoreAgent(77621) allow file-read-xattr /Users/danekapoor/Library/Developer/Xcode/DerivedData/WonderWhisper_Mac-etopzasemmdxcbcnjiilnrcrnhlh/Build/Products/Debug/WonderWhisper Mac.app/Contents/MacOS/WonderWhisper Mac
default	10:47:34.709162+0800	runningboardd	Calculated state for app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>: running-active (role: UserInteractiveFocal) (endowments: <private>)
default	10:47:34.709728+0800	ControlCenter	Received state update for 79189 (app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>, running-active-NotVisible
default	10:47:34.709826+0800	gamepolicyd	Received state update for 79189 (app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>, running-active-NotVisible
default	10:47:34.712805+0800	kernel	Sandbox: ContextStoreAgent(77621) allow file-read-data /Users/danekapoor/Library/Developer/Xcode/DerivedData/WonderWhisper_Mac-etopzasemmdxcbcnjiilnrcrnhlh/Build/Products/Debug/WonderWhisper Mac.app/Contents/Info.plist
default	10:47:40.697870+0800	runningboardd	Assertion did invalidate due to timeout: 402-367-63075 (target:[app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>:79189])
default	10:47:40.902548+0800	runningboardd	[app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>:79189] Ignoring jetsam update because this process is not memory-managed
default	10:47:40.902563+0800	runningboardd	[app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>:79189] Ignoring suspend because this process is not lifecycle managed
default	10:47:40.902570+0800	runningboardd	[app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>:79189] Ignoring GPU update because this process is not GPU managed
default	10:47:40.902584+0800	runningboardd	[app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>:79189] Ignoring memory limit update because this process is not memory-managed
default	10:47:40.909174+0800	runningboardd	Calculated state for app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>: running-active (role: UserInteractiveFocal) (endowments: <private>)
default	10:47:40.909868+0800	ControlCenter	Received state update for 79189 (app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>, running-active-NotVisible
default	10:47:40.910320+0800	gamepolicyd	Received state update for 79189 (app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>, running-active-NotVisible
default	10:47:47.151432+0800	runningboardd	Invalidating assertion 402-367-63073 (target:[app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>:79189]) from originator [osservice<com.apple.coreservices.launchservicesd>:367]
default	10:47:47.157094+0800	runningboardd	Invalidating assertion 402-397-63074 (target:[app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>:79189]) from originator [osservice<com.apple.WindowServer(88)>:397]
default	10:47:47.270929+0800	runningboardd	[app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>:79189] Ignoring jetsam update because this process is not memory-managed
default	10:47:47.270973+0800	runningboardd	[app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>:79189] Ignoring suspend because this process is not lifecycle managed
default	10:47:47.271047+0800	runningboardd	[app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>:79189] Set darwin role to: UserInteractiveNonFocal
default	10:47:47.271184+0800	runningboardd	[app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>:79189] Ignoring GPU update because this process is not GPU managed
default	10:47:47.271353+0800	runningboardd	[app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>:79189] Ignoring memory limit update because this process is not memory-managed
default	10:47:47.278305+0800	runningboardd	Calculated state for app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>: running-active (role: UserInteractiveNonFocal) (endowments: <private>)
default	10:47:47.280544+0800	ControlCenter	Received state update for 79189 (app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>, running-active-NotVisible
default	10:47:47.301198+0800	gamepolicyd	Received state update for 79189 (app<application.com.slumdev88.wonderwhisper.WonderWhisper-Mac.331319086.331337254.3FAEA90D-86E5-4ED2-9154-355C83FBC9E1(501)>, running-active-NotVisible



[PERF] persistPromptLibrary: JSON encode took 3.381967544555664ms
[PERF] persistPromptLibrary: total took 3.791928291320801ms
Installed Carbon event handler for hotkeys
Registered toggle hotkey keyCode=96 mods=0 status=0
Registered paste hotkey keyCode=9 mods=4352 status=0
Metrics req=? ctx=- proto=h2 dns=0.021000s connect=0.141000s tls=0.126000s ttfb=0.021997s transfer=0.000042s
Metrics req=? ctx=- proto=h2 dns=0.021000s connect=0.140000s tls=0.124000s ttfb=0.023904s transfer=0.000128s
Metrics req=? ctx=- proto=h2 dns=0.022000s connect=0.141000s tls=0.125000s ttfb=0.029425s transfer=0.000096s
Metrics req=? ctx=- proto=h2 dns=0.021000s connect=0.143000s tls=0.127000s ttfb=0.049913s transfer=0.000092s
AddInstanceForFactory: No factory registered for id <CFUUID 0xa9dc84400> F8BB1C28-BAE8-11D6-9C31-00039315CD46
More than one bundle with the same factory UUID detected: {
    "ff5ed090-1521-11ea-8d71-362b9e155667" = "BlackHole_Create";
} in CFBundle 0xa9bca4c40 </Library/Audio/Plug-Ins/HAL/VirtualDesktopSpeakers.driver> (not loaded) and CFBundle/CFPlugIn 0xa9bca4b60 </Library/Audio/Plug-Ins/HAL/VirtualDesktopMicrophone.driver> (not loaded)
Unable to obtain a task name port right for pid 397: (os/kern) failure (0x5)
Metrics req=? ctx=- proto=h3 dns=-1.000000s connect=-1.000000s tls=-1.000000s ttfb=0.102787s transfer=0.001727s
Metrics req=? ctx=- proto=h3 dns=-1.000000s connect=-1.000000s tls=-1.000000s ttfb=0.107749s transfer=0.001661s
Metrics req=? ctx=- proto=h3 dns=0.013000s connect=0.073000s tls=0.071000s ttfb=0.109526s transfer=0.000179s
Metrics req=? ctx=- proto=h3 dns=0.015000s connect=0.072000s tls=0.071000s ttfb=0.110961s transfer=0.000114s
Metrics req=? ctx=- proto=h3 dns=-1.000000s connect=-1.000000s tls=-1.000000s ttfb=0.107886s transfer=0.001530s
Metrics req=? ctx=- proto=h3 dns=0.012000s connect=0.074000s tls=0.072000s ttfb=0.109500s transfer=0.000161s
Metrics req=? ctx=- proto=h3 dns=-1.000000s connect=-1.000000s tls=-1.000000s ttfb=0.112569s transfer=0.001562s
Metrics req=? ctx=- proto=h3 dns=0.014000s connect=0.074000s tls=0.072000s ttfb=0.117077s transfer=0.000160s
It's not legal to call -layoutSubtreeIfNeeded on a view which is already being laid out.  If you are implementing the view's -layout method, you can call -[super layout] instead.  Break on void _NSDetectedLayoutRecursion(void) to debug.  This will be logged only once.  This may break in the future.

Installed Carbon event handler for hotkeys
Registered toggle hotkey keyCode=96 mods=0 status=0
Registered paste hotkey keyCode=9 mods=4352 status=0
Metrics req=? ctx=- proto=h2 dns=0.016000s connect=0.500000s tls=0.485000s ttfb=0.028250s transfer=0.000043s
Metrics req=? ctx=- proto=h2 dns=0.004000s connect=0.501000s tls=0.486000s ttfb=0.027017s transfer=0.000152s
Metrics req=? ctx=- proto=h2 dns=0.003000s connect=0.502000s tls=0.487000s ttfb=0.027454s transfer=0.000054s
Metrics req=? ctx=- proto=h2 dns=0.016000s connect=0.500000s tls=0.484000s ttfb=0.034934s transfer=0.000049s
AddInstanceForFactory: No factory registered for id <CFUUID 0xb06c13e80> F8BB1C28-BAE8-11D6-9C31-00039315CD46
More than one bundle with the same factory UUID detected: {
    "ff5ed090-1521-11ea-8d71-362b9e155667" = "BlackHole_Create";
} in CFBundle 0xb08144700 </Library/Audio/Plug-Ins/HAL/VirtualDesktopSpeakers.driver> (not loaded) and CFBundle/CFPlugIn 0xb081447e0 </Library/Audio/Plug-Ins/HAL/VirtualDesktopMicrophone.driver> (not loaded)
Unable to obtain a task name port right for pid 397: (os/kern) failure (0x5)
Metrics req=? ctx=- proto=h3 dns=0.348000s connect=0.052000s tls=0.048000s ttfb=0.115209s transfer=0.002326s
Metrics req=? ctx=- proto=h3 dns=-1.000000s connect=-1.000000s tls=-1.000000s ttfb=0.117436s transfer=0.000274s
Metrics req=? ctx=- proto=h3 dns=-1.000000s connect=-1.000000s tls=-1.000000s ttfb=0.117935s transfer=0.001818s
Metrics req=? ctx=- proto=h3 dns=-1.000000s connect=-1.000000s tls=-1.000000s ttfb=0.136543s transfer=0.006305s
Metrics req=? ctx=- proto=h3 dns=0.347000s connect=0.054000s tls=0.052000s ttfb=0.142986s transfer=0.000436s
Metrics req=? ctx=- proto=h3 dns=0.347000s connect=0.053000s tls=0.050000s ttfb=0.143868s transfer=0.000236s
Metrics req=? ctx=- proto=h3 dns=0.005000s connect=0.095000s tls=0.092000s ttfb=0.102601s transfer=0.011359s
Metrics req=? ctx=- proto=h3 dns=-1.000000s connect=-1.000000s tls=-1.000000s ttfb=0.114352s transfer=0.000289s
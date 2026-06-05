import SwiftUI

/// PreferenceKey used to measure the natural combined height of the
/// power display + gauges block, so the LCDContainer (used by every
/// sub-menu) can match it exactly. Keeping both the same height means
/// the controls row below doesn't shift when you switch between normal
/// view and SETUP, so mouse-click positions stay put.
struct NormalContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct ContentView: View {
    @Environment(AmplifierViewModel.self) private var vm
    /// Measured height of PowerDisplay + Gauges. Populated the first
    /// time the normal view is rendered; stays set afterwards so
    /// sub-menus can match it.
    /// Pre-seeded with a reasonable default so banners (powered-off,
    /// alerts, sub-menus) get the right size on the very first render
    /// — before the normal Power+Gauges block has ever rendered to
    /// measure itself. Replaced as soon as that measurement arrives.
    @State private var normalBlockHeight: CGFloat = 230
    /// Dev panels (RCU Capture + RCU Parser Debug) are hidden by default;
    /// the user can toggle them on via the ladybug button in the title
    /// bar when they need to diagnose parser / pipeline issues. Setting
    /// is persisted across launches.
    @AppStorage("showDevPanels") private var showDevPanels: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text("SPE \(vm.detectedModel.displayName)")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                // Developer-panels toggle. Compact ladybug glyph so it
                // doesn't crowd the title bar; yellow when active.
                Button {
                    showDevPanels.toggle()
                } label: {
                    Image(systemName: "ladybug")
                        .font(.system(size: 12))
                        .foregroundStyle(showDevPanels ? .yellow : Color(white: 0.4))
                }
                .buttonStyle(.plain)
                .help(showDevPanels ? "Hide developer panels" : "Show developer panels (RCU capture + parser debug)")
                ConnectionIndicator(isConnected: vm.isConnected, status: vm.statusMessage)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(white: 0.08))

            ScrollView {
                VStack(spacing: 6) {
                    ConnectionView()
                    if showDevPanels {
                        CaptureView()
                    }

                    if vm.isConnected {
                        // RCU parser debug overlay — only visible when the
                        // developer-panels toggle is on.
                        if showDevPanels {
                            RCUDebugView()
                        }

                        // Swap between normal display, setup menu, sub-menus,
                        // CAT/DISP info overlay, and amp-powered-off banner.
                        if !vm.isAmpResponding {
                            AmpOffBannerView()
                                .frame(height: normalBlockHeight > 0 ? normalBlockHeight : nil)
                                .transition(.opacity)
                        } else if !vm.state.error.isEmpty || !vm.state.warnings.isEmpty {
                            AlertBannerView()
                                .frame(height: normalBlockHeight > 0 ? normalBlockHeight : nil)
                                .transition(.opacity)
                        } else if vm.isShowingInfoScreen {
                            InfoScreenView()
                                .frame(height: normalBlockHeight > 0 ? normalBlockHeight : nil)
                                .transition(.opacity)
                        } else if let subMenu = vm.activeSubMenu {
                            subMenuView(for: subMenu)
                                .frame(height: normalBlockHeight > 0 ? normalBlockHeight : nil)
                                .transition(.opacity)
                        } else if vm.isInSetupMode {
                            SetupMenuView()
                                .frame(height: normalBlockHeight > 0 ? normalBlockHeight : nil)
                                .transition(.opacity)
                        } else if vm.state.opStatus == "Stby" && !vm.isStandbyTX {
                            // In STANDBY mirror the amp's LCD as a banner
                            // in place of the power meter, but keep
                            // GaugesView below — DRAIN / TEMP / VOLTAGE
                            // are still meaningful while idle (PSU
                            // voltage, ambient temp), and SWR pins to
                            // 1.0. The whole VStack is pinned to
                            // normalBlockHeight so toggling between
                            // STANDBY / SETUP / OPERATE doesn't shift
                            // anything below; the banner takes the
                            // leftover space above the gauges.
                            //
                            // Exception: if the rig is keyed while the
                            // amp is in STANDBY (bypass), fall through to
                            // PowerDisplay+Gauges so the operator can
                            // see the drive level. PowerDisplayView caps
                            // the scale at 200 W in this state.
                            VStack(spacing: 6) {
                                StandbyBannerView()
                                GaugesView()
                            }
                            .frame(height: normalBlockHeight > 0 ? normalBlockHeight : nil)
                            .transition(.opacity)
                        } else {
                            VStack(spacing: 6) {
                                PowerDisplayView()
                                GaugesView()
                            }
                            .background(
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: NormalContentHeightKey.self,
                                        value: geo.size.height)
                                }
                            )
                            .onPreferenceChange(NormalContentHeightKey.self) { h in
                                if h > 0 { normalBlockHeight = h }
                            }
                            .transition(.opacity)
                        }

                        LEDStatusView()
                        StatusChipsView()
                        ControlsView()
                    }
                }
                .padding(8)
            }
        }
        .frame(minWidth: 380, minHeight: 520)
        .background(Color(white: 0.11))
        .preferredColorScheme(.dark)
    }
}

extension ContentView {
    @ViewBuilder
    func subMenuView(for subMenu: AmplifierViewModel.SetupSubMenu) -> some View {
        switch subMenu {
        case .config: ConfigSubMenuView()
        case .antenna: AntennaSubMenuView()
        case .cat: CATSubMenuView()
        case .manualTune: ManualTuneSubMenuView()
        case .display: DisplaySubMenuView()
        case .beep: BeepSubMenuView()
        case .start: StartSubMenuView()
        case .tempFans: TempFansSubMenuView()
        case .alarmsLog: AlarmsLogSubMenuView()
        case .tunAnt: TunAntSubMenuView()
        case .rxAnt: RxAntSubMenuView()
        case .yaesuModel: YaesuModelSubMenuView()
        case .tenTecModel: TenTecModelSubMenuView()
        case .baudRate: BaudRateSubMenuView()
        case .tunAntPort: TunAntPortSubMenuView()
        }
    }
}

struct ConnectionIndicator: View {
    let isConnected: Bool
    let status: String

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isConnected ? Color.green : Color.red.opacity(0.7))
                .frame(width: 7, height: 7)
                .shadow(color: isConnected ? .green.opacity(0.6) : .clear, radius: 3)
            Text(status.isEmpty ? (isConnected ? "Connected" : "Disconnected") : status)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

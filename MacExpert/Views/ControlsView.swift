import SwiftUI

struct ControlsView: View {
    @Environment(AmplifierViewModel.self) private var vm
    @State private var showPowerOffConfirm = false
    @State private var showPowerOnConfirm = false
    @State private var showSweepPanel = false
    @State private var showRadioPanel = false

    var body: some View {
        VStack(spacing: 4) {
            // Row 1: Buttons that DON'T duplicate the tappable status chips
            // above. INPUT / ANT / BAND / LEVEL(POWER) / OPER(MODE) are
            // exposed via their chips, so we only keep panel-only actions
            // here: TUNE, DISP, SET, CAT.
            HStack(spacing: 4) {
                PanelButton("TUNE", icon: "tuningfork") {
                    vm.sendCommand(.tune)
                }
                PanelButton("DISP", icon: "display") {
                    vm.sendCommand(.display)
                }
                // CAT in the middle; SET pinned to the edge so it's the
                // easiest button to hit (biggest mouse target on a
                // right-edge hover).
                PanelButton("CAT", icon: "point.3.connected.trianglepath.dotted") {
                    vm.sendCommand(.cat)
                }
                PanelButton("SET", icon: "gearshape",
                            accent: vm.isInSetupMode ? .green : nil) {
                    vm.sendCommand(.set)
                }
                // SWEEP — opens the band-sweep modal (Phase 2c). The
                // existing TUNE button above stays as a plain keycode
                // send; SWEEP is the orchestrated alternative that
                // drives the Flex carrier + watches the RCU TUNE bit.
                PanelButton("SWEEP", icon: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                            accent: vm.isSweeping ? .green : nil) {
                    showSweepPanel = true
                }
                // RADIO — pick which rig drives TUNE/SWEEP (Flex vs SunSDR)
                // and edit its settings; applies live on the Pi.
                PanelButton("RADIO", icon: "antenna.radiowaves.left.and.right") {
                    showRadioPanel = true
                }
            }

            // Row 2: ATU tuning + menu navigation.
            HStack(spacing: 4) {
                PanelButton("\u{25C0}L", icon: "minus") {
                    vm.sendCommand(.lMinus)
                }
                PanelButton("L\u{25B6}", icon: "plus") {
                    vm.sendCommand(.lPlus)
                }
                PanelButton("\u{25C0}C", icon: "minus") {
                    vm.sendCommand(.cMinus)
                }
                PanelButton("C\u{25B6}", icon: "plus") {
                    vm.sendCommand(.cPlus)
                }
                PanelButton("\u{25C0}", icon: "chevron.left",
                            accent: vm.isInSetupMode ? .green : nil) {
                    vm.sendCommand(.leftArrow)
                }
                PanelButton("\u{25B6}", icon: "chevron.right",
                            accent: vm.isInSetupMode ? .green : nil) {
                    vm.sendCommand(.rightArrow)
                }
            }

            // Power on/off
            HStack(spacing: 6) {
                Button {
                    showPowerOnConfirm = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "power").font(.system(size: 10))
                        Text("POWER ON").font(.system(size: 10, weight: .bold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 26)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green.opacity(0.8))
                .confirmationDialog("Power On the amplifier?", isPresented: $showPowerOnConfirm) {
                    Button("Power On") { vm.powerOn() }
                    Button("Cancel", role: .cancel) {}
                }

                Button {
                    showPowerOffConfirm = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "power").font(.system(size: 10))
                        Text("POWER OFF").font(.system(size: 10, weight: .bold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 26)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red.opacity(0.8))
                .confirmationDialog("Power Off the amplifier?", isPresented: $showPowerOffConfirm) {
                    Button("Power Off", role: .destructive) { vm.powerOff() }
                    Button("Cancel", role: .cancel) {}
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.13)))
        .sheet(isPresented: $showSweepPanel) {
            SweepPanelView()
        }
        .sheet(isPresented: $showRadioPanel) {
            RadioSettingsView()
        }
    }
}

struct PanelButton: View {
    let title: String
    let icon: String
    var accent: Color?
    let action: () -> Void

    init(_ title: String, icon: String, accent: Color? = nil, action: @escaping () -> Void) {
        self.title = title; self.icon = icon; self.accent = accent; self.action = action
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(accent ?? .cyan)
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(accent ?? Color(white: 0.65))
                    .tracking(0.3)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(white: 0.18))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke((accent ?? .cyan).opacity(0.15), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}

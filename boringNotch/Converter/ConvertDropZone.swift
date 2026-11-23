//
//  ConvertDropZone.swift
//  boringNotch
//
//  The "Convert" square that sits next to AirDrop on the shelf. Dropping files
//  here hands them to the converter; the shelf then shows the options.
//

import SwiftUI
import UniformTypeIdentifiers

struct ConvertDropZone: View {
    @EnvironmentObject private var vm: BoringViewModel
    @ObservedObject private var model = ConverterViewModel.shared

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(LinearGradient(colors: [Color.black.opacity(0.35), Color.black.opacity(0.20)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            vm.converterDropTargeting ? Color.effectiveAccent.opacity(0.9) : Color.white.opacity(0.1),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [10])
                        )
                )
                .shadow(color: Color.black.opacity(0.6), radius: 6, x: 0, y: 2)

            VStack(spacing: 5) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(vm.converterDropTargeting ? 0.11 : 0.09))
                        .frame(width: 55, height: 55)
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(vm.converterDropTargeting ? Color.effectiveAccent : Color.gray)
                        .rotationEffect(.degrees(vm.converterDropTargeting ? 180 : 0))
                        .scaleEffect(vm.converterDropTargeting ? 1.06 : 1.0)
                        .animation(.spring(response: 0.45, dampingFraction: 0.7), value: vm.converterDropTargeting)

                }
                Text("Convert")
                    .font(.system(.headline, design: .rounded))
                    .foregroundColor(.white.opacity(0.8))
            }
            .padding(18)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onDrop(of: [.fileURL, .item], isTargeted: $vm.converterDropTargeting) { providers in
            dragLog.info("drop: convert box, \(providers.count) item(s)")
            vm.dropEvent = true
            model.load(providers)
            return true
        }
        .onTapGesture { model.chooseFiles() }
        .help("Drop files to convert them, or click to choose")
    }
}

import CoreLocation
import SwiftUI

struct ContentView: View {

    @StateObject private var watch = WatchLink()
    @State private var target = Date()
    @State private var banner: Banner?
    @State private var busy = false

    private struct Banner {
        let text: String
        let isError: Bool
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    connectionRow

                    if watch.isConnected {
                        clockCard
                    } else {
                        watchListCard
                    }

                    if let banner {
                        bannerRow(banner)
                    }

                    logCard
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Ollee Time")
        }
    }

    // MARK: - Connection

    private var connectionRow: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
            Text(watch.status.label)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            if watch.isConnected {
                Button("Disconnect") { watch.disconnect() }
                    .font(.footnote)
            } else {
                Button("Rescan") { watch.rescan() }
                    .font(.footnote)
            }
        }
        .padding(.horizontal, 4)
    }

    private var statusColor: Color {
        switch watch.status {
        case .connected: return .green
        case .scanning, .connecting: return .orange
        case .bluetoothOff, .unauthorized: return .red
        case .idle: return .gray
        }
    }

    // MARK: - Watch picker

    private var watchListCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose your watch")
                .font(.headline)
            Text("Wake the watch, close the official Ollee app, then tap it below.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if watch.devices.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Searching…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            } else {
                ForEach(Array(watch.devices.prefix(15))) { device in
                    Button {
                        banner = nil
                        watch.connect(to: device)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name)
                                    .foregroundStyle(.primary)
                                Text("\(device.rssi) dBm")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)

                    if device.id != watch.devices.prefix(15).last?.id {
                        Divider()
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Clock

    private var clockCard: some View {
        VStack(spacing: 16) {
            Text("Send this time to the watch")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            DatePicker("", selection: $target, displayedComponents: .hourAndMinute)
                .datePickerStyle(.wheel)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .frame(height: 130)
                .clipped()

            Button {
                send(targetTimeOnToday())
            } label: {
                HStack(spacing: 8) {
                    if busy {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    Text(busy ? "Sending…" : "Set watch to \(target.formatted(date: .omitted, time: .shortened))")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy)

            Button("Use current time") {
                let now = Date()
                target = now
                send(now)
            }
            .font(.footnote)
            .disabled(busy)

            Text("Today's date and your phone's current UTC offset are sent along with the time.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Banner

    private func bannerRow(_ banner: Banner) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(banner.isError ? .orange : .green)
            Text(banner.text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Log

    private var logCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Activity")
                    .font(.headline)
                Spacer()
                Button("Clear") { watch.clearLog() }
                    .font(.caption)
            }

            if watch.log.isEmpty {
                Text("Nothing yet.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(watch.log.suffix(10)) { entry in
                    Text(entry.text)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Actions

    /// Today's date with the hour/minute chosen in the picker.
    private func targetTimeOnToday() -> Date {
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.hour, .minute], from: target)
        return calendar.date(bySettingHour: parts.hour ?? 0,
                             minute: parts.minute ?? 0,
                             second: 0,
                             of: Date()) ?? target
    }

    private func send(_ date: Date) {
        banner = nil
        busy = true

        Task { @MainActor in
            let coordinate = await PhoneLocation().currentCoordinate()
            do {
                let outcome = try await watch.sendClock(at: date, coordinate: coordinate)
                let time = date.formatted(date: .omitted, time: .shortened)
                banner = outcome.acknowledged
                    ? Banner(text: "The watch confirmed the clock is now \(time).", isError: false)
                    : Banner(text: "Frame sent, but no confirmation arrived. The clock is usually still set — wake the watch and retry if it did not change.", isError: true)
            } catch {
                banner = Banner(text: error.localizedDescription, isError: true)
            }
            busy = false
        }
    }
}


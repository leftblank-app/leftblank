import Foundation
import SwiftUI

/// The form behind a chip, generated from the function's `#let` signature and
/// shared by the Mac and the iPad. Apply writes every change back as one source
/// replacement (`ChipEditing.edit`), so one undo restores the call.
public struct ChipForm: View {
    public struct Field: Identifiable, Equatable {
        public var id: String {
            name
        }

        public let name: String
        /// Labelled values offer a picker instead of free text.
        public let choices: [ChipValueLabel]?
        public var value: String
    }

    private let chip: Chip
    @State private var fields: [Field]
    @State private var error: String?
    private let apply: ([String: String]) throws -> Void
    private let cancel: () -> Void

    /// `apply` receives the parameters whose values changed or were added.
    public init(
        chip: Chip,
        signature: FunctionSignature,
        formatter: ChipFormatter,
        apply: @escaping ([String: String]) throws -> Void,
        cancel: @escaping () -> Void,
    ) {
        self.chip = chip
        _fields = State(initialValue: Self.fields(chip: chip, signature: signature, formatter: formatter))
        self.apply = apply
        self.cancel = cancel
    }

    static func fields(chip: Chip, signature: FunctionSignature, formatter: ChipFormatter) -> [Field] {
        signature.parameters.map { parameter in
            let current = chip.arguments.first { $0.name == parameter.name }?.literal
            let fallback = parameter.defaultSource.map { Presentation.decodeString($0) ?? $0 } ?? ""
            return Field(
                name: parameter.name,
                choices: formatter.labels(callee: chip.callee, parameter: parameter.name),
                value: current ?? fallback,
            )
        }
    }

    /// The values to write: changed arguments and newly filled parameters.
    static func values(_ fields: [Field], chip: Chip) -> [String: String] {
        var values: [String: String] = [:]
        for field in fields {
            if let argument = chip.arguments.first(where: { $0.name == field.name }) {
                if argument.literal != field.value {
                    values[field.name] = field.value
                }
            } else if !field.value.isEmpty {
                values[field.name] = field.value
            }
        }
        return values
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(chip.callee).font(.headline)
            ForEach($fields) { $field in
                VStack(alignment: .leading, spacing: 4) {
                    Text(field.name).font(.caption).foregroundStyle(.secondary)
                    if let choices = field.choices {
                        Picker(field.name, selection: $field.value) {
                            ForEach(choices, id: \.value) { choice in
                                Text(choice.label).tag(choice.value)
                            }
                            if !choices.contains(where: { $0.value == field.value }) {
                                Text(field.value).tag(field.value)
                            }
                        }.labelsHidden().accessibilityIdentifier("chip-\(field.name)")
                    } else {
                        TextField(field.name, text: $field.value)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("chip-\(field.name)")
                    }
                }
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.caption)
            }
            HStack {
                Button(L10n.text("Cancel"), action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.text("Apply")) {
                    do {
                        try apply(Self.values(fields, chip: chip))
                    } catch let failure as ChipEditing.Failure {
                        error = Self.message(failure)
                    } catch {
                        self.error = error.localizedDescription
                    }
                }.keyboardShortcut(.defaultAction).accessibilityIdentifier("chip-apply")
            }
        }.padding(16).frame(minWidth: 280, idealWidth: 320)
    }

    static func message(_ failure: ChipEditing.Failure) -> String {
        switch failure {
        case let .unknownParameter(name): L10n.format("Unknown parameter %@", name)
        case let .invalidLiteral(parameter, value): L10n.format("%@ is not a valid value for %@", value, parameter)
        case let .missingArgument(name): L10n.format("Fill in %@ first", name)
        }
    }
}

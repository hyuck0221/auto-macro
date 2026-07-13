import Testing

@main
struct AutoMacroSwiftTestingRunner {
    static func main() async {
        await Testing.__swiftPMEntryPoint() as Never
    }
}

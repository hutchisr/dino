import Foundation

func geckoDebugLog(_ format: String, _ args: CVarArg...) {
#if DEBUG || targetEnvironment(simulator)
    withVaList(args) { NSLogv(format, $0) }
#endif
}

#!/usr/bin/env swift
// macOS structural checks; Xcode separately type-checks UIKit and builds the app.
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
func readPlist(_ path: String) throws -> [String: Any] {
    let data = try Data(contentsOf: root.appendingPathComponent(path))
    guard let value = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
        fatalError("Invalid property list: \(path)")
    }
    return value
}
let project = try readPlist("MilkOrbit.xcodeproj/project.pbxproj")
let objects = project["objects"] as! [String: [String: Any]]
let projectObject = objects[project["rootObject"] as! String]!

func checkReferences(_ value: Any) {
    if let object = value as? [String: Any] { object.values.forEach(checkReferences) }
    else if let array = value as? [Any] { array.forEach(checkReferences) }
    else if let string = value as? String,
            string.range(of: "^[A-F0-9]{24}$", options: .regularExpression) != nil {
        precondition(objects[string] != nil, "Unresolved Xcode reference: \(string)")
    }
}
checkReferences(project)

var appSources = Set<String>()
func checkGroup(_ identifier: String, relativeTo parent: URL) {
    let object = objects[identifier]!
    if object["sourceTree"] as? String == "BUILT_PRODUCTS_DIR" { return }
    let location = (object["path"] as? String).map { parent.appendingPathComponent($0) } ?? parent
    if let children = object["children"] as? [String] {
        children.forEach { checkGroup($0, relativeTo: location) }
    } else if object["isa"] as? String == "PBXFileReference" {
        precondition(FileManager.default.fileExists(atPath: location.path), "Missing project file: \(location.path)")
        if location.pathExtension == "swift" {
            if location.deletingLastPathComponent().lastPathComponent == "MilkOrbitApp" {
                appSources.insert(location.lastPathComponent)
            }
        }
    }
}
checkGroup(projectObject["mainGroup"] as! String, relativeTo: root)
let diskSources = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Sources/MilkOrbitApp").path)
    .filter { $0.hasSuffix(".swift") }
precondition(appSources == Set(diskSources), "App source files and project references differ")

let targets = projectObject["targets"] as! [String]
let appIDs = targets.filter { objects[$0]?["productType"] as? String == "com.apple.product-type.application" }
precondition(targets.count == 1 && appIDs.count == 1, "Expected one app-only Xcode target")
let appID = appIDs[0]
let appTarget = objects[appID]!
let phases = (appTarget["buildPhases"] as! [String]).map { objects[$0]! }
let compiledSources = phases.filter { $0["isa"] as? String == "PBXSourcesBuildPhase" }
    .flatMap { $0["files"] as! [String] }
    .map { objects[objects[$0]!["fileRef"] as! String]!["path"] as! String }
precondition(Set(compiledSources) == appSources && compiledSources.count == appSources.count,
             "App source build phase is incomplete or contains duplicates")
let resources = phases.filter { $0["isa"] as? String == "PBXResourcesBuildPhase" }
    .flatMap { $0["files"] as! [String] }
    .map { objects[objects[$0]!["fileRef"] as! String]!["path"] as! String }
precondition(resources.contains("PrivacyInfo.xcprivacy") && resources.contains("Sources/MilkOrbitApp/Assets.xcassets"),
             "App privacy manifest or asset catalog missing from resources phase")
let packageProducts = (appTarget["packageProductDependencies"] as! [String]).map { objects[$0]! }
precondition(packageProducts.contains { $0["productName"] as? String == "OrbitCore" }, "OrbitCore product missing")
let localPackage = objects[packageProducts.first!["package"] as! String]!
precondition(localPackage["relativePath"] as? String == ".", "Expected local package at repository root")

_ = try readPlist("Config/Info.plist")
_ = try readPlist("Config/PrivacyInfo.xcprivacy")
let scheme = try Data(contentsOf: root.appendingPathComponent("MilkOrbit.xcodeproj/xcshareddata/xcschemes/MilkOrbit.xcscheme"))
final class SchemeReferences: NSObject, XMLParserDelegate {
    var identifiers = Set<String>()
    var containsTestAction = false
    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if let id = attributes["BlueprintIdentifier"] { identifiers.insert(id) }
        if elementName == "TestAction" || elementName == "TestableReference" { containsTestAction = true }
    }
}
let references = SchemeReferences()
let parser = XMLParser(data: scheme)
parser.delegate = references
precondition(parser.parse(), "Invalid shared scheme XML")
precondition(references.identifiers == Set([appID]), "Shared scheme must reference only the app target")
precondition(!references.containsTestAction, "Expected an app-only shared scheme; core tests run through SwiftPM")
let catalog = root.appendingPathComponent("Sources/MilkOrbitApp/Assets.xcassets")
let manifests = FileManager.default.enumerator(at: catalog, includingPropertiesForKeys: nil)!
for case let manifest as URL in manifests where manifest.lastPathComponent == "Contents.json" {
    let contents = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [String: Any]
    for key in ["images", "data"] {
        for entry in contents[key] as? [[String: Any]] ?? [] {
            if let filename = entry["filename"] as? String {
                let asset = manifest.deletingLastPathComponent().appendingPathComponent(filename)
                precondition(FileManager.default.fileExists(atPath: asset.path), "Missing catalog asset: \(asset.path)")
            }
        }
    }
}
print("Xcode references, app source/resource membership, local package, property lists, app-only scheme, and catalog assets validated.")

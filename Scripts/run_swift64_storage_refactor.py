from pathlib import Path

source_path = Path("Scripts/apply_swift64_storage_refactor.py")
source = source_path.read_text(encoding="utf-8")

# SwiftSonic is a real source dependency (OpenSubsonicClient + Settings UI),
# so retain the package and its license while applying the rest of the refactor.
scan_start = source.index("# A package that is not referenced by source code")
scan_end = source.index("\n\nstorage_identity =", scan_start)
source = source[:scan_start] + "# SwiftSonic retained: verified source dependency.\n" + source[scan_end:]

package_remove_start = source.index(
    'replace_once(\n    "project.yml",\n    "  SwiftSonic:'
)
package_remove_end = source.index("\n\nresolved_path =", package_remove_start)
source = source[:package_remove_start] + source[package_remove_end:]

resolved_start = source.index("resolved_path = Path(\"Package.resolved\")")
resolved_end = source.index("\n\n\nverify_script =", resolved_start)
source = source[:resolved_start] + source[resolved_end:]

license_start = source.index(
    "# Remove the unused dependency's license section and update Nuke metadata."
)
license_end = source.index(
    "# The old document exists solely for the now-removed OS-specific artifact.",
    license_start,
)
license_replacement = '''# Keep SwiftSonic licensing; update the Nuke version metadata only.\nlicense_path = "BuFi/Resources/ThirdPartyLicenses.txt"\nlicense_text = read(license_path)\nlicense_text = license_text.replace("Nuke 13.0.6", "Nuke 13.1.0")\nlicense_text = license_text.replace("Nuke/tree/13.0.6", "Nuke/tree/13.1.0")\nlicense_text = license_text.replace("Nuke/blob/13.0.6/LICENSE", "Nuke/blob/13.1.0/LICENSE")\nwrite(license_path, license_text)\n\n\n'''
source = source[:license_start] + license_replacement + source[license_end:]

sanity_old = '''project = read("project.yml")\nif "SwiftSonic" in project or "swiftsonic" in read("Package.resolved").lower():\n    raise RuntimeError("SwiftSonic removal incomplete")\nif 'xcodeVersion: "27.0"' not in project:\n'''
sanity_new = '''project = read("project.yml")\nif "SwiftSonic" not in project or "swiftsonic" not in read("Package.resolved").lower():\n    raise RuntimeError("SwiftSonic dependency was unexpectedly removed")\nif 'xcodeVersion: "27.0"' not in project:\n'''
if sanity_old not in source:
    raise RuntimeError("sanity marker missing")
source = source.replace(sanity_old, sanity_new, 1)

exec(compile(source, str(source_path), "exec"), {"__name__": "__main__"})

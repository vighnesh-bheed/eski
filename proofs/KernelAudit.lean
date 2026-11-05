import Lean

open Lean

namespace KernelAudit

instance : MonadEnv (StateM Environment) where
  getEnv := get
  modifyEnv := modify

def dependencies (env : Environment) (name : Name) : Array Name :=
  (collectAxioms name : StateM Environment (Array Name)).run' env

def inventory (modules : Array Name) : IO Json := do
  initSearchPath (← findSysroot)
  let mut artifacts := []
  for name in modules do
    artifacts := artifacts ++ [(name.toString, toJson (← findOLean name).toString)]
  let env ← importModules (modules.map fun name => {module := name}) {} 0
  let imported := env.allImportedModuleNames
  for name in modules do
    unless (env.getModuleIdx? name).isSome do
      throw (IO.userError s!"project module not imported: {name}")
  let mut declarations := #[]
  for (name, info) in env.checked.get.constants.toList do
    if let some idx := env.getModuleIdxFor? name then
      let origin := imported[idx.toNat]!
      if modules.contains origin then
        let kind := if info.isTheorem then "theorem" else if info.isAxiom then "axiom" else "declaration"
        let axioms := dependencies env name
        declarations := declarations.push (Json.mkObj [
          ("name", toJson name.toString), ("module", toJson origin.toString),
          ("kind", toJson kind), ("axioms", toJson (axioms.map Name.toString))])
  return Json.mkObj [("modules", toJson (modules.map Name.toString)),
    ("module_artifacts", Json.mkObj artifacts), ("declarations", Json.arr declarations)]

end KernelAudit

def main (args : List String) : IO Unit := do
  let [request, output] := args | throw (IO.userError "expected module inventory and output paths")
  let contents ← IO.FS.readFile request
  let modules := (contents.splitOn "\n").filterMap fun line =>
    if line.isEmpty then none else some line.toName
  if modules.isEmpty then throw (IO.userError "empty project module inventory")
  let result ← KernelAudit.inventory modules.toArray
  IO.FS.writeFile output (result.compress ++ "\n")

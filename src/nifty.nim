import 
  json,
  os,
  parseopt,
  logging,
  algorithm,
  strutils,
  sequtils

import
  niftypkg/niftylogger

newNiftyLogger().addHandler()
setLogFilter(lvlInfo)

import
  niftypkg/config,
  niftypkg/project,
  niftypkg/messaging

let usage* = """  $1 v$2 - $3
  (c) 2017-2020 $4

  Usage:
    nifty <command> [<package>]           Executes <command> (on <package>).

    => For more information on available commands, run: nifty help

  Options:
    --log, -l               Specifies the log level (debug|info|notice|warn|error|fatal).
                            Default: info
    --force, -f             Do not ask for confirmation when executing the specified command.
    --help, -h              Displays this message.
    --version, -h           Displays the version of the application.
""" % [pkgTitle, pkgVersion, pkgDescription, pkgAuthor]

var force = false

# Helper Methods

proc addProperty(parentObj: JsonNode, name = ""): tuple[key: string, value: JsonNode] =
  var done = false
  while (not done):
    if name == "":
      result.key = editValue("Name")
    elif name == "name":
      warn "Property identifier 'name' cannot be modified."
    else:
      printValue(" Name", name)
      result.key = name
    var ok = false
    while (not ok):
      var value = ""
      if parentObj.hasKey(result.key):
        value = $parentObj[result.key]
      try:
        result.value = editValue("Value", value).parseJson
        if (result.value == newJNull()):
          ok = confirm("Remove property '$1'?" % result.key)
          done = true
        else:
          ok = true
      except:
        warn("Please enter a valid JSON value.")
    done = done or confirm("OK?")

proc addProperties(obj: var JsonNode) =
  var done = false
  while (not done):
    let prop = addProperty(obj)
    obj[prop.key] = prop.value
    done = not confirm("Do you want to add/remove more properties?")

proc changeValue(oldv: tuple[label: string, value: JsonNode], newv: tuple[label: string, value: JsonNode]): bool =
  if oldv.value != newJNull():
    printDeleted(oldv.label, $oldv.value)
  if newv.value != newJNull():
    printAdded(newv.label, $newv.value)
  return confirm("Confirm change?")

proc confirmAndRemoveDir(dir: string) =
  let answer = force or confirm "Delete directory '$1' and all its contents?" % dir
  if answer:
    dir.removeDir()

proc confirmAndRemoveFile(file: string) =
  let answer = force or confirm "Delete file '$1'? [y/n]" % file 
  if answer: 
    file.removeFile()

proc confirmAndRemovePackage(pkg: string) =
  if pkg.fileExists():
    pkg.confirmAndRemoveFile()
  elif pkg.dirExists():
    pkg.confirmAndRemoveDir()
  else:
    warn "Package '$1' not found." % pkg

proc buildTree(prj: NiftyProject, dir: string): TreeNode =
  var node = newTreeNode(dir.extractFilename)
  for k, v in prj.packages.pairs:
    var d = dir / prj.storage / k
    var p = newNiftyProject(d)
    if p.configured:
      p.load
      node.add buildTree(p, d)
    else:
      node.add newTreeNode(k)
  return node

proc updateDefinitions(prj: var NiftyProject): bool =
  result = false
  let sysCommands = niftyTpl.parseJson["commands"]
  for k, v in sysCommands.pairs:
    if prj.commands.hasKey(k):
      let sysCommand = sysCommands[k]
      var prjCommand = prj.commands[k]
      for prop, val in sysCommand.pairs:
        let sysProp = sysCommand[prop]
        var prjProp = newJNull()
        if prjCommand.hasKey(prop):
          prjProp = prjCommand[prop]
        if prjProp != newJNull():
          if prjProp != sysProp:
            let sysVal = (label: k & "." & prop, value: sysProp)
            let prjVal = (label: k & "." & prop, value: prjProp)
            if changeValue(prjVal, sysVal):
              prjCommand[prop] = sysProp
              result = true
        else:
          result = true
          # Adding new property
          printAdded("$1.$2" % [k, prop], $sysProp)
          prjCommand[prop] = sysProp
    else:
      result = true
      # Adding new command
      printAdded(k, $sysCommands[k])
      prj.commands[k] = sysCommands[k]

### MAIN ###

var args = newSeq[string](0)

for kind, key, val in getopt():
  case kind:
    of cmdArgument:
      args.add key 
    of cmdLongOption, cmdShortOption:
      case key:
        of "force", "f":
          force = true
        of "log", "l":
          var val = val
          setLogLevel(val)
        of "help", "h":
          echo usage
          quit(0)
        of "version", "v":
          echo pkgVersion
          quit(0)
        else:
          discard
    else:
      discard

var prj = newNiftyProject(getCurrentDir())

if args.len == 0:
  echo usage
  quit(0)
case args[0]:
  of "init":
    if prj.configured:
      fatal "Project already configured."
      quit(2)
    var storage = "packages"
    if args.len > 2:
      storage = args[1]
    prj.init(storage)
    notice "Project initialized using '$1' as storage directory." % storage
  of "purge":
    prj.load
    confirmAndRemoveDir(prj.dir/prj.storage) 
  of "map":
    if args.len < 2:
      fatal "No package specified."
      quit(3)
    let alias = args[1]
    var props = newJObject()
    prj.load
    if prj.packages.hasKey(alias):
      notice "Remapping existing package: " & alias
      warn "Specify properties for package '$1':" % alias
      props = prj.packages[alias]
      for k, v in props.mpairs:
        if k == "name":
          continue
        let prop = addProperty(props, k)
        props[prop.key] = prop.value
      if confirm "Do you want to add/remove more properties?":
        addProperties(props)
    else:
      notice "Mapping new package: " & alias
      warn "Specify properties for package '$1':" % alias
      addProperties(props)
    prj.map(alias, props) 
  of "unmap":
    if args.len < 2:
      fatal "No package specified."
      quit(3)
    let alias = args[1]
    prj.load
    if not prj.packages.hasKey(alias):
      fatal "Package '$1' not defined." % [alias]
      quit(4)
    if force or confirm("Remove mapping for package '$1'?" % alias):
      prj.unmap(alias) 
  of "remove":
    prj.load
    if args.len < 2:
      var packages = toSeq(prj.packages.pairs)
      if packages.len == 0:
        warn "No packages defined - nothing to do."
      else:
        for key, val in prj.packages.pairs:
          confirmAndRemovePackage(prj.storage/key)
    else:
      confirmAndRemovePackage(prj.storage/args[1])
  of "list":
    prj.load
    let pwd = getCurrentDir()
    echo buildTree(prj, pwd).tree
  of "info":
    if args.len < 2:
      fatal "No package specified."
      quit(3)
    prj.load
    let alias = args[1]
    if not prj.packages.hasKey(alias):
      fatal "Package '$1' not defined." % [alias]
      quit(4)
    let data = prj.packages[alias]
    for k, v in data.pairs:
      echo "$1:\t$2" % [k, $v]
  of "help":
    echo ""
    if args.len < 2:
      var sortedKeys = toSeq(prj.help.keys)
      sortedKeys.sort(cmp[string])
      for k in sortedKeys:
        printGreen "   nifty $1" % prj.help[k]["_syntax"].getStr
        echo "\n      $1\n" % prj.help[k]["_description"].getStr
    else:
      let cmd = args[1]
      let help = prj.help[cmd]
      if not prj.help.hasKey(cmd):
        fatal "Command '$1' is not defined." % cmd
        quit(5)
      printGreen "   nifty " & help["_syntax"].getStr
      echo "\n      $1\n" % help["_description"].getStr
  of "update":
    prj.load
    if updateDefinitions(prj):
      prj.save
  else:
    if args.len < 1:
      echo usage
      quit(1)
    if args.len < 2:
      prj.load
      var packages = toSeq(prj.packages.pairs)
      if packages.len == 0:
        warn "No packages defined - nothing to do."
        quit(0)
      if args[0].startsWith("$"):
        # Execute task list
        let tasklist = args[0][1.. args[0].len - 1]
        if prj.tasklists.isNil or not prj.tasklists.hasKey(tasklist):
          warn "Task list '$1' not defined in project" % [tasklist]
          quit(0)
        let tasks = prj.tasklists[tasklist].getElems
        for task in tasks:
          let targs = task.getStr.split(" ").mapIt(it.strip)
          discard execute(prj, targs[0], targs[1])
        quit(0)
      for key, val in prj.packages.pairs:
        prj.executeRec(args[0], key) 
    else:
      prj.executeRec(args[0], args[1]) 

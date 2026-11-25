# Aurora UI 2.0 — Components Reference

Every component created on a Tab, Section, CollapsibleSection, Card, or Groupbox returns a handle with `SetVisible(bool)` and `Destroy()`, plus `Set` / `Get` where applicable.

## Containers
- `AddSection(name)`
- `AddCollapsibleSection({ Name, Default })` -> `SetExpanded(bool)`, `IsExpanded()`
- `AddCard({ Title?, Subtitle? })`
- `AddGroupbox(name)`

## Display
- `AddLabel(text)` -> `Set(text)`, `Get()`
- `AddParagraph({ Title, Content })` -> `Set(content)`, `SetTitle(title)`, `Get()`
- `AddDivider(text?)`
- `AddImage({ Image, Height?, ScaleType?, Caption? })` -> `Set(assetId)`, `Get()`
- `AddProgressBar({ Name, Min?, Max?, Default?, Suffix?, Flag? })` -> `Set(value)`, `Get()`
- `AddLoadingIndicator({ Text?, Active? })` -> `SetText(text)`, `SetActive(bool)`
- `AddEmptyState({ Icon?, Title?, Description?, ActionText?, OnAction? })` -> `Set(title, desc)`

## Interactive
- `AddButton({ Name, Description?, Confirm?, ConfirmTitle?, Danger?, Tooltip?, Callback })` -> `Fire()`, `SetText(text)`
- `AddToggle({ Name, Description?, Default?, Flag?, Tooltip?, Callback })` -> `Set(bool, silent?)`, `Get()`
- `AddCheckbox({ Name, Default?, Flag?, Tooltip?, Callback })` -> `Set(bool, silent?)`, `Get()`
- `AddRadioGroup({ Name, Options, Default?, Flag?, Callback })` -> `Set(value, silent?)`, `Get()`
- `AddSlider({ Name, Min, Max, Increment?, Default?, Suffix?, Flag?, Tooltip?, Callback })` -> `Set(num, silent?)`, `Get()`

## Selection & Color
- `AddDropdown({ Name, Options, Multi?, Default?, Flag?, Tooltip?, Callback })` -> `Set(val, silent?)`, `Get()`, `Refresh(newOpts)`
- `AddMultiDropdown({ Name, Options, Default?, Flag?, Tooltip?, Callback })`
- `AddSearchBar({ Placeholder?, Flag?, Callback })` -> `Set(text)`, `Get()`, `Clear()`
- `AddColorPicker({ Name, Default?, Flag?, Tooltip?, Callback })` -> `Set(Color3, silent?)`, `Get()`, `GetHex()`, `SetHex(hex, silent?)`

## Inputs & System
- `AddInput({ Name, Placeholder?, Default?, Numeric?, Flag?, Tooltip?, Callback })` -> `Set(str, silent?)`, `Get()`
- `AddTextArea({ Name, Placeholder?, Default?, Height?, Flag?, Tooltip?, Callback })` -> `Set(str, silent?)`, `Get()`
- `AddKeybind({ Name, Default?, Flag?, OnChange?, Callback })` -> `Set(KeyCodeOrName, silent?)`, `Get()`
- `AddKeybindList({ Name? })` -> `Refresh()`
- `AddProfileSelector({ Name? })` -> `Refresh()`

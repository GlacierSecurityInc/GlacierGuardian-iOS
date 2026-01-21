## Strings & Localization

### Adding a new string

* Open `strings.json` in your favorite editor.
* Add a new dictionary to the array with the following format:
	* Name of String in all caps with underscores (this will be the name used in XCode).
	* Add the string with the key `string`.
	* Add a comment that describes how the string is used with the key `comment`
* Run `StringsConverter.py` (requires Python 2.7+)

```
$ python3 ./OTRAssets/Strings/StringsConverter.py
```

### Finding Unused Strings

StringsUnused.py requires Python 3.6 or higher.

```
$  python3 ./Glacier/Classes/Assets/Strings/StringsUnused.py ./Glacier/Classes/ ./Glacier/Classes/Assets/
```

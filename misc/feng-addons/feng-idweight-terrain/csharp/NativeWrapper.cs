using System;
using System.Diagnostics;
using System.Linq;
using System.Reflection;
using Godot;

namespace TokisanGames;

// Each closed generic keeps its own script cache, just as each wrapper did.
internal static class NativeWrapper<T> where T : GodotObject
{
	private static CSharpScript _wrapperScriptAsset;

	public static T Bind(GodotObject godotObject)
	{
		if (!GodotObject.IsInstanceValid(godotObject))
			return null;

		if (godotObject is T wrapperScriptInstance)
			return wrapperScriptInstance;

#if DEBUG
		var expectedType = typeof(T);
		var currentObjectClassName = godotObject.GetClass();
		if (!ClassDB.IsParentClass(currentObjectClassName, expectedType.Name))
			throw new InvalidOperationException($"The supplied GodotObject ({currentObjectClassName}) is not the {expectedType.Name} type.");
#endif

		if (_wrapperScriptAsset is null)
		{
			var scriptPathAttribute = typeof(T).GetCustomAttributes<ScriptPathAttribute>().FirstOrDefault();
			if (scriptPathAttribute is null) throw new UnreachableException();
			_wrapperScriptAsset = ResourceLoader.Load<CSharpScript>(scriptPathAttribute.Path);
		}

		var instanceId = godotObject.GetInstanceId();
		godotObject.SetScript(_wrapperScriptAsset);
		return (T)GodotObject.InstanceFromId(instanceId);
	}
}

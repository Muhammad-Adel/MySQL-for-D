/***********************
Module to contain all helper general purpose functions
*/
module MySqlForD.Functions;

import MySqlForD.Exceptions;
import std.bitmanip;
import std.system;
import std.variant;

/************************************
*Read a null terminated string from an unsigned byte array. If it is not null terminated it reads till the end of the array

*Reading starts fron index 0 till the first null terminated string. The bytes that are consumed are removed from the input byte array

* Throws InvalidArgumentException if input contained no null string
*/
pure string ReadString(ref ubyte[] input)
{
	ulong indexOfLastCharacter = input.length -1;
	foreach(i, b; input)
	{
		if (b =='\0')
		{
			indexOfLastCharacter = i;
			break;
		}
	}
	//read the string ignoring the null character at the end 
	char[] characters;
	characters.length= indexOfLastCharacter;
	characters[] = cast (char[]) input[0..indexOfLastCharacter];
	
	//remove consumed characters from input array 
	input = input[indexOfLastCharacter+1 .. $];

	return cast (string) characters;
}
/*************************************
Write a string to a byte array starting from a given index. The index is set to the first array element after the added string
*/
void WriteString(ref ubyte[] byteArray,string inputString,ref uint index)
{
	foreach(character;inputString)
	{
		byteArray[index]=character;
		index++;
	}
}
/***************************************************************
A length encoded integer is an integer that consumes 1, 3, 4, or 9 bytes, depending on its numeric value. The bytes of the int are consumed from input array
*/
ulong ReadLengthEncodedInteger(ref ubyte[] input)
{
	if (input[0] < 0xfb)
	{
		//1 byte integer
		uint result = input[0];
		input = input[1..$];
		return result;
	}
	if (input[0] == 0xfc)
	{
		//two bytes integer
		input = input[1..$];
		ushort result = read!(ushort,endian.littleEndian)(input);
		return result;
	}
	if (input[0]==0xfd)
	{
		//four bytes integer
		input = input[1..$];
		uint result = read!(uint,endian.littleEndian)(input);
		return result;
	}
	if (input[0]== 0xfe)
	{
		//eight bytes integer
		input = input[1..$];
		ulong result = read!(ulong,endian.littleEndian)(input);
		return result;
	}
	throw new InvalidArgumentException("Invalid input value");
	
}

ubyte[] ConvertToLengthEncodedInteger(long value)
{
	ubyte[]output;
	if (value < 251)
	{
		output.length = 1;
		output[0] = cast(ubyte)value;
	}
	else if (value >= 251 && value < (2^16) )
	{
		output.length = 3;
		output[0] = 0xfc;
		write!(ushort,Endian.littleEndian)(output,cast(ushort)value,1);
	}
	return output;

}

/**********************************************************************************
Get the size of the data stored inside a variant structure
*/
 uint GetVariantSize(Variant value)
{
	if (value.type == typeid(string))
	{
		string stringValue = value.get!(string);

		//get string length as a length encode integer
		ubyte[] stringLength = ConvertToLengthEncodedInteger(stringValue.length);
		
		return cast (uint) stringValue.length + cast(uint) stringLength.length;
	}
	if (value.type == typeid(float))
	{
		return float.sizeof;
	}
	else if (value.type == typeid(double))
	{
		return double.sizeof;
	}
	if (value.type == typeid(int))
	{
		return int.sizeof;
	}
	throw new InvalidArgumentException("unknown variant type");
}

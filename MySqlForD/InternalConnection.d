module MySqlForD.InternalConnection;


import std.socket;
import std.bitmanip;
import std.system;
import std.digest.sha;
import std.variant;
import std.datetime;
import std.stdio;

import MySqlForD.Functions;
import MySqlForD.Exceptions;
import MySqlForD.ConnectionParameters;
import MySqlForD.CommandResult;
import MySqlForD.PreparedStatement;
import MySqlForD.PreparedStatementPacketHandler;
import MySqlForD.PacketHandler;

/***********************************
This is a connection that should be pooled later (didn't write pooling code yet). This is why I had to create an Internal connection object separate from the exposed Connection object. This pooling should be transparent to the Connection class
user, this is why it is not exported
The reason for not creating a separate module for this class is that is is the only class that has acccess to the constructor of PreparedStatement class
*/
 class InternalConnection:PacketHandler {

	static const uint AUTHENTICATION_PLUGIN_DATA_PART1_LENGTH			=	8;
	static const uint RESERVED_SERVER_STRING_LENGTH						=	10;
	static const uint SERVER_STATUS_LENGTH								=	2;
	static const uint RESERVED_CLIENT_STRING_LENGTH						=	23;

	private ConnectionParameters	_ConnectionParameters;
	private uint					_ProtocolVersion;
	private Socket					_Socket;
	private string					_ServerVersion;
	private uint					_ConnectionId;
	private string					_AuthenticationPluginName;
	private ubyte					_ServerCharacterSet;
	private uint					_ServerCapabilities;
	private ubyte[2]				_ServerStatus;
	private ubyte[]					_ServerAuthenticationPluginData;
	private bool					_IsConnected  = false;
	private PreparedStatementPacketHandler	_PreparedStatementPacketHandler;

	/*********************************************************************
	Buffer used for differnt tasks to avoid successive allocation and deallocation
	*/
	private ubyte[]					_TempBuffer;

	private enum CapabilityFlags
	{
		CLIENT_PROTOCOL_41			=	0x00000200,
		CLIENT_LONG_PASSWORD		=	0x00000001,
		CLIENT_CONNECT_WITH_DB		=   0x00000008,
		CLIENT_SECURE_CONNECTION	=   0x00008000,
		CLIENT_MULTI_STATEMENTS     =	0x00010000
	}
	private enum PreparedStatementCommands
	{
		COM_STMT_PREPARE = 22,
		COM_STMT_EXECUTE = 23,
		COM_STMT_SEND_LONG_DATA = 24,
		COM_STMT_CLOSE = 25

	}

	private @property uint ProtocolVersion()
	{
		return _ProtocolVersion;
	}

	
	@property{ 
		string ServerVersion ()
		{
			return _ServerVersion;
		}
		bool IsConnected()
		{
			return _IsConnected;
		}
	}
	
	private @property
	{ 
		PreparedStatementPacketHandler PreparedStatementHandler()
		{
			if (_PreparedStatementPacketHandler is null)
				_PreparedStatementPacketHandler = new PreparedStatementPacketHandler();
			return _PreparedStatementPacketHandler;
		}
	}
	
	this()
	{
		_Socket = new TcpSocket();
		_TempBuffer.length = 1024*1024;
	}

	void Connect(ConnectionParameters parameters)
	{
		_ConnectionParameters = parameters;
		_Socket.connect(new InternetAddress(parameters.ServerAddress,parameters.Port));
		
		PacketHeader header = GetPacketHeader();
		ubyte[] buffer;
		buffer.length = header.PacketLength;
		_Socket.receive(buffer);
	
		ushort initial_byte = buffer[0];

		if (initial_byte == 0xFF)
			ProcessErrorMessage(buffer);
		else
		{
			ProcessInitialHandshakeMessage(buffer);
			SendClientHandshakeResponseMessage();
			HandleServerHandshakeResponse();
		}

	}
	private PacketHeader GetPacketHeader()
	{
		ubyte[] buffer;
		buffer.length = 4;
		_Socket.receive(buffer);
		return ExtractPacketHeader(buffer);
	}
	
	private void ProcessErrorMessage (ref ubyte[] error)
	{

	}
	
	private void ProcessInitialHandshakeMessage(ref ubyte[] initialHandshakeMessage)
	{
		_ProtocolVersion = initialHandshakeMessage[0];
		//remove bytes we have consumed
		initialHandshakeMessage = initialHandshakeMessage[1..$];

		_ServerVersion = ReadString(initialHandshakeMessage);
		_ConnectionId = read! (uint,Endian.littleEndian)(initialHandshakeMessage);

		ubyte[] authPluginDataPart1 = initialHandshakeMessage[0..AUTHENTICATION_PLUGIN_DATA_PART1_LENGTH];
		//remove bytes we have consumed
		initialHandshakeMessage = initialHandshakeMessage[AUTHENTICATION_PLUGIN_DATA_PART1_LENGTH..$];
		//remove filler byte
		initialHandshakeMessage = initialHandshakeMessage[1..$];
		
		ubyte[4] serverCapabilitiesBytes;
		//server capabilities lower bytes
		serverCapabilitiesBytes[0..2]= initialHandshakeMessage[0..2];
		initialHandshakeMessage = initialHandshakeMessage[2..$];

		_ServerCharacterSet = initialHandshakeMessage[0];
		initialHandshakeMessage = initialHandshakeMessage[1..$];

		_ServerStatus = initialHandshakeMessage[0..SERVER_STATUS_LENGTH];
		initialHandshakeMessage = initialHandshakeMessage[SERVER_STATUS_LENGTH..$];
		
		//server capabilities uper bytes
		serverCapabilitiesBytes[2..4] = initialHandshakeMessage[0..2];
		initialHandshakeMessage = initialHandshakeMessage[2..$];
		_ServerCapabilities = peek!(uint,Endian.littleEndian)(cast (ubyte[]) serverCapabilitiesBytes);


		uint totalLentgthOfAuthPluginData = initialHandshakeMessage[0];
		//remove bytes we have consumed
		initialHandshakeMessage = initialHandshakeMessage[1..$];

		//skip empty reserved string
		initialHandshakeMessage = initialHandshakeMessage[RESERVED_SERVER_STRING_LENGTH .. $];
		
		uint lengthOfAuthPluginDataPart2 = totalLentgthOfAuthPluginData -8;
		ubyte[]authPluginDataPart2=  initialHandshakeMessage[0 .. lengthOfAuthPluginDataPart2];
		

		//remove bytes we consumed
		initialHandshakeMessage = initialHandshakeMessage[lengthOfAuthPluginDataPart2..$];

		_AuthenticationPluginName = ReadString(initialHandshakeMessage); 

		assert (_AuthenticationPluginName == "mysql_native_password");
		assert (authPluginDataPart2[$-1] == '\0');
		assert (authPluginDataPart2.length == 13);

		_ServerAuthenticationPluginData.length = 20;
		_ServerAuthenticationPluginData[0..8]=authPluginDataPart1;
		_ServerAuthenticationPluginData[8..$]=authPluginDataPart2[0..12];
	}

	private void SendClientHandshakeResponseMessage()
	{
		//create an alias for _TempBuffer to slice easily without _TempBuffer gets affected. first 4 bytes are for packet header that we will write at the end of this method
		ubyte[] handshakeResponseMessage = _TempBuffer[4..$];

		uint currentIndex =0;

		uint capabilities =GenerateCapabilityFlags();
		write!(uint,Endian.littleEndian)(handshakeResponseMessage,capabilities,currentIndex);
		currentIndex += 4;

		//maximum size for a command that we may send to the database.we put no resteriction from our side
		write!(uint,Endian.littleEndian)(handshakeResponseMessage,0,currentIndex);
		currentIndex +=4;

		//use the default character set for mysql which is latin1_swedish_ci 
		write!(ubyte,Endian.littleEndian)(handshakeResponseMessage, 0x08 ,currentIndex);
		currentIndex ++;

		uint endOfReservedClientStringIndex = currentIndex + RESERVED_CLIENT_STRING_LENGTH;
		//reserved client string, all set to zero
		for(;currentIndex < endOfReservedClientStringIndex;currentIndex++)
		{
			handshakeResponseMessage[currentIndex]=0;
		}

		//strings in D are not null terminated and the protocol expected a null terminated string for the username
		string userName = _ConnectionParameters.Username ~ "\0";
		WriteString(handshakeResponseMessage,userName,currentIndex);

		ubyte[] authenticationResponse =  GenerateAuthenticationResponse();
		handshakeResponseMessage[currentIndex]= cast(ubyte) authenticationResponse.length;
		currentIndex++;
		handshakeResponseMessage[currentIndex..currentIndex+authenticationResponse.length] = authenticationResponse;
		currentIndex +=authenticationResponse.length;


		if ( capabilities & CapabilityFlags.CLIENT_CONNECT_WITH_DB)
		{
			string databaseName = _ConnectionParameters.DatabaseName ~'\0' ;
			WriteString(handshakeResponseMessage,databaseName,currentIndex);
		}

		AddPacketHeader(_TempBuffer,currentIndex,1);
		_Socket.send(_TempBuffer[0..currentIndex + PACKT_HEADER_LENGTH]);

	}
	
	private uint GenerateCapabilityFlags()
	{
		uint capabilities =0;
		capabilities = capabilities | CapabilityFlags.CLIENT_PROTOCOL_41;
		capabilities = capabilities | CapabilityFlags.CLIENT_LONG_PASSWORD;
		if ( _ConnectionParameters.DatabaseName.length > 0 && (_ServerCapabilities & CapabilityFlags.CLIENT_CONNECT_WITH_DB))
			capabilities = capabilities | CapabilityFlags.CLIENT_CONNECT_WITH_DB;
		capabilities = capabilities | CapabilityFlags.CLIENT_SECURE_CONNECTION;
		if (_ServerCapabilities & CapabilityFlags.CLIENT_MULTI_STATEMENTS)
			capabilities = capabilities | CapabilityFlags.CLIENT_MULTI_STATEMENTS;

		return capabilities;
	}
	
	private pure ubyte[] GenerateAuthenticationResponse()
	{
		ubyte[] hashedPassword = sha1Of(_ConnectionParameters.Password);
		ubyte[] hashOfHashedPassword = sha1Of(hashedPassword);
		ubyte[40] concatenatedArray;
		concatenatedArray[0..20] = _ServerAuthenticationPluginData;
		concatenatedArray[20..$] = hashOfHashedPassword;
		ubyte[] concatenatedHash = sha1Of(concatenatedArray);
		ubyte[] authenticationResponse;
		authenticationResponse.length = 20;
		for(int i=0;i<hashedPassword.length;i++)
		{
			authenticationResponse[i]=hashedPassword[i] ^ concatenatedHash[i];
		}
		return authenticationResponse;
	}
	
	private void HandleServerHandshakeResponse()
	{
		PacketHeader header = GetPacketHeader();
		ubyte[] buffer;
		buffer.length = header.PacketLength;
		_Socket.receive(buffer);
		
		if (buffer[0]==0xff)
		{
			ParseErrorPacket(buffer);
		}
		if (buffer[0]==0x00)
		{
			_IsConnected = true;
			GetOkPacketResponse(buffer);
			return;
		}
		MySqlDException ex = new MySqlDException("Unknown server response");
		ex.ServerResponse = buffer;
		throw ex;

	}
	
	
	private CommandResult GetOkPacketResponse(ubyte[]packet)
	{
		//first byte is 0x00, ok indicator. Since the call was passed here we assume its value and skip it
		packet = packet[1..$];
		CommandResult result = new CommandResult();
		result.NumberOfRowsAffected = ReadLengthEncodedInteger(packet);
		result.LastInsertedId = ReadLengthEncodedInteger(packet);

		//TODO: put a meaningful status description in command result class
		ushort status = read!(ushort,endian.littleEndian)(packet);
		
		result.NumberOfWarnings = read!(ushort,endian.littleEndian)(packet);
		return result;

	}
	PreparedStatement PrepareStatement(string statement)
	{
		//create an alias for _TempBuffer to slice easily without _TempBuffer gets affected. first 4 bytes are for packet header that we will write at the end of this method
		ubyte[] preparedStatementPacket = _TempBuffer[4..$];

		uint packetLength = PreparedStatementHandler.GeneratePrepareStatementPacket(preparedStatementPacket,statement);
		AddPacketHeader(_TempBuffer,packetLength,0);
		_Socket.send(_TempBuffer[0..packetLength + PACKT_HEADER_LENGTH]);

		return GetComStmtPrepareResponse();

	}
	private PreparedStatement GetComStmtPrepareResponse()
	{
		//create an alias for _TempBuffer to slice easily without _TempBuffer gets affected
		PacketHeader header = GetPacketHeader();
		ubyte[] responseBuffer;
		responseBuffer.length = header.PacketLength;
		_Socket.receive(responseBuffer);
		
		PreparedStatement statement = PreparedStatementHandler.ParsePrepareStatementResponseFirstPacket(responseBuffer);
		
		if (statement.ParametersCount>0)
		{
			for(int i=0;i<statement.ParametersCount;i++)
			{
				PacketHeader parameterDefinitionPacketHeader = GetPacketHeader();
				responseBuffer.length = parameterDefinitionPacketHeader.PacketLength;
				_Socket.receive (responseBuffer);
			}
			/*TODO: we can use information about parameter definition and return them as members in the prepared statemen object. later 
			this info can be used for some error checking before acutally sending the parameters to the server for prepared statement execution*/

			PacketHeader eofPacketHeader = GetPacketHeader();
			responseBuffer.length = eofPacketHeader.PacketLength;
			_Socket.receive (responseBuffer);
			
		}
		if (statement.ColumnsCount >0)
		{
			for(int i=0;i<statement.ColumnsCount;i++)
			{
				PacketHeader columnDefinitionPacketHeader = GetPacketHeader();
				responseBuffer.length = columnDefinitionPacketHeader.PacketLength;
				_Socket.receive (responseBuffer);
			}
			/*TODO: we can use information about column definition and return them as members in the prepared statemen object. later 
			this info can be used for some error checking before acutally sending the parameters to the server for prepared statement execution*/

			PacketHeader eofPacketHeader = GetPacketHeader();
			responseBuffer.length = eofPacketHeader.PacketLength;
			_Socket.receive (responseBuffer);
		}
		return statement;

	}
	public void ClosePreparedStatement(uint statementId)
	{
		/*write the packet length in the first 4 bytes (packet header). The protocol specifies that only 3 bytes are for the packet length and the forth is for the packet sequence. 
		We will overwrite the forth byte later*/
		write!(uint,Endian.littleEndian)(_TempBuffer,5,0);
		//write the packet sequeence in the forth byte
		_TempBuffer[3]=0;

		//first 4 bytes are for packet header
		uint currentIndex =4;

		_TempBuffer[currentIndex]= PreparedStatementCommands.COM_STMT_CLOSE;
		currentIndex++;
		write!(uint,Endian.littleEndian)(_TempBuffer,statementId,currentIndex);
		currentIndex += 4;
		_Socket.send(_TempBuffer[0..currentIndex]);
	}
	public CommandResult ExecuteCommandPreparedStatement(uint statementId,Variant[] parameters = null)
	{
		ExecutePreparedStatement(statementId,parameters);
		return GetCommandComStmtExecuteResponse();
	}
	private void ExecutePreparedStatement(uint statementId,Variant[] parameters = null)
	{
		//first 4 bytes are for packet header that we will write at the end of this method
		ubyte[] preparedStatementPacket = _TempBuffer[4..$];

		uint packetSize = PreparedStatementHandler.GeneratePreparedStatementExecutePacket(preparedStatementPacket,statementId,parameters);
		AddPacketHeader(_TempBuffer,packetSize,0);

		_Socket.send(_TempBuffer[0..packetSize + PACKT_HEADER_LENGTH]);
	}





	CommandResult GetCommandComStmtExecuteResponse()
	{
		PacketHeader header = GetPacketHeader();
		ubyte[] responseBuffer ;
		responseBuffer.length = header.PacketLength;
		_Socket.receive(responseBuffer);

		if (responseBuffer[0]==0x00)
		{
			return GetOkPacketResponse(responseBuffer);
		}
		else if (responseBuffer[0]== 0xff)
		{
			ParseErrorPacket (responseBuffer);
		}
		throw new MySqlDException("Prepared statement executed is not  a command statement");

	}
	
	void Disconnect()
	{
		_Socket.shutdown(SocketShutdown.BOTH);
		_Socket.close();
		_IsConnected = false;
	}
	

}









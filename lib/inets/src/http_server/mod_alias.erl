%%
%% %CopyrightBegin%
%%
%% Copyright Ericsson AB 1997-2010. All Rights Reserved.
%%
%% The contents of this file are subject to the Erlang Public License,
%% Version 1.1, (the "License"); you may not use this file except in
%% compliance with the License. You should have received a copy of the
%% Erlang Public License along with this software. If not, it can be
%% retrieved online at http://www.erlang.org/.
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and limitations
%% under the License.
%%
%% %CopyrightEnd%
%%
%%
-module(mod_alias).

-export([do/1, 
	 real_name/3,
	 real_script_name/3,
	 default_index/2,
	 load/2,
	 store/2,
	 path/3]).

-include("httpd.hrl").
-include("httpd_internal.hrl").

-define(VMODULE,"ALIAS").

%% do

do(#mod{data = Data} = Info) ->
    ?hdrt("do", []),
    case proplists:get_value(status, Data) of
	%% A status code has been generated!
	{_StatusCode, _PhraseArgs, _Reason} ->
	    {proceed, Data};
	%% No status code has been generated!
	undefined ->
	    case proplists:get_value(response, Data) of
		%% No response has been generated!
		undefined ->
		    do_alias(Info);
		%% A response has been generated or sent!
		_Response ->
		    {proceed, Data}
	    end
    end.

do_alias(#mod{config_db   = ConfigDB, 
	      request_uri = ReqURI,
	      data        = Data}) ->
    {ShortPath, Path, AfterPath} = 
	real_name(ConfigDB, ReqURI, which_alias(ConfigDB)),
    ?hdrt("real name", 
	  [{request_uri, ReqURI}, 
	   {short_path,  ShortPath}, 
	   {path,        Path}, 
	   {after_path,  AfterPath}]),
    %% Relocate if a trailing slash is missing else proceed!
    LastChar = lists:last(ShortPath),
    case file:read_file_info(ShortPath) of 
	{ok, FileInfo} when ((FileInfo#file_info.type =:= directory) andalso 
			     (LastChar =/= $/)) ->
	    ?hdrt("directory and last-char is a /", []),
	    ServerName = which_server_name(ConfigDB), 
	    Port = port_string( which_port(ConfigDB) ),
	    URL = "http://" ++ ServerName ++ Port ++ ReqURI ++ "/",
	    ReasonPhrase = httpd_util:reason_phrase(301),
	    Message = httpd_util:message(301, URL, ConfigDB),
	    {proceed,
	     [{response,
	       {301, ["Location: ", URL, "\r\n"
		      "Content-Type: text/html\r\n",
		      "\r\n",
		      "<HTML>\n<HEAD>\n<TITLE>",ReasonPhrase,
		      "</TITLE>\n</HEAD>\n"
		      "<BODY>\n<H1>",ReasonPhrase,
		      "</H1>\n", Message, 
		      "\n</BODY>\n</HTML>\n"]}}|
	      [{real_name, {Path, AfterPath}} | Data]]};
	_NoFile ->
	    {proceed, [{real_name, {Path, AfterPath}} | Data]}
    end.

port_string(80) ->
    "";
port_string(Port) ->
    ":" ++ integer_to_list(Port).

%% real_name

real_name(ConfigDB, RequestURI, []) ->
    DocumentRoot = which_document_root(ConfigDB), 
    RealName = DocumentRoot ++ RequestURI,
    {ShortPath, _AfterPath} = httpd_util:split_path(RealName),
    {Path, AfterPath} = 
	httpd_util:split_path(default_index(ConfigDB, RealName)),
    {ShortPath, Path, AfterPath};

real_name(ConfigDB, RequestURI, [{FakeName,RealName}|Rest]) ->
     case inets_regexp:match(RequestURI, "^" ++ FakeName) of
	{match, _, _} ->
	    {ok, ActualName, _} = inets_regexp:sub(RequestURI,
					     "^" ++ FakeName, RealName),
 	    {ShortPath, _AfterPath} = httpd_util:split_path(ActualName),
	    {Path, AfterPath} =
	       httpd_util:split_path(default_index(ConfigDB, ActualName)),
	    {ShortPath, Path, AfterPath};
	 nomatch ->
	     real_name(ConfigDB, RequestURI, Rest)
    end.

%% real_script_name

real_script_name(_ConfigDB, _RequestURI, []) ->
    not_a_script;
real_script_name(ConfigDB, RequestURI, [{FakeName,RealName} | Rest]) ->
    case inets_regexp:match(RequestURI, "^" ++ FakeName) of
	{match,_,_} ->
	    {ok, ActualName, _} = 
		inets_regexp:sub(RequestURI, "^" ++ FakeName, RealName),
	    httpd_util:split_script_path(default_index(ConfigDB, ActualName));
	nomatch ->
	    real_script_name(ConfigDB, RequestURI, Rest)
    end.

%% default_index

default_index(ConfigDB, Path) ->
    case file:read_file_info(Path) of
	{ok, FileInfo} when FileInfo#file_info.type =:= directory ->
	    DirectoryIndex = which_directory_index(ConfigDB),
	    append_index(Path, DirectoryIndex);
	_ ->
	    Path
    end.

append_index(RealName, []) ->
    RealName;
append_index(RealName, [Index | Rest]) ->
    case file:read_file_info(filename:join(RealName, Index)) of
	{error, _Reason} ->
	    append_index(RealName, Rest);
	_ ->
	    filename:join(RealName, Index)
    end.

%% path

path(Data, ConfigDB, RequestURI) ->
    case proplists:get_value(real_name, Data) of
	undefined ->
	    DocumentRoot = which_document_root(ConfigDB), 
	    {Path, _AfterPath} = 
		httpd_util:split_path(DocumentRoot ++ RequestURI),
	    Path;
	{Path, _AfterPath} ->
	    Path
    end.

%%
%% Configuration
%%

%% load

load("DirectoryIndex " ++ DirectoryIndex, []) ->
    {ok, DirectoryIndexes} = inets_regexp:split(DirectoryIndex," "),
    {ok,[], {directory_index, DirectoryIndexes}};
load("Alias " ++ Alias, []) ->
    case inets_regexp:split(Alias," ") of
	{ok, [FakeName, RealName]} ->
	    {ok,[],{alias,{FakeName,RealName}}};
	{ok, _} ->
	    {error,?NICE(httpd_conf:clean(Alias)++" is an invalid Alias")}
    end;
load("ScriptAlias " ++ ScriptAlias, []) ->
    case inets_regexp:split(ScriptAlias, " ") of
	{ok, [FakeName, RealName]} ->
	    %% Make sure the path always has a trailing slash..
	    RealName1 = filename:join(filename:split(RealName)),
	    {ok, [], {script_alias, {FakeName, RealName1++"/"}}};
	{ok, _} ->
	    {error, ?NICE(httpd_conf:clean(ScriptAlias)++
			  " is an invalid ScriptAlias")}
    end.

store({directory_index, Value} = Conf, _) when is_list(Value) ->
    case is_directory_index_list(Value) of
	true ->
	    {ok, Conf};
	false ->
	    {error, {wrong_type, {directory_index, Value}}}
    end;
store({directory_index, Value}, _) ->
    {error, {wrong_type, {directory_index, Value}}};
store({alias, {Fake, Real}} = Conf, _) 
  when is_list(Fake) andalso is_list(Real) ->
    {ok, Conf};
store({alias, Value}, _) ->
    {error, {wrong_type, {alias, Value}}};
store({script_alias, {Fake, Real}} = Conf, _) 
  when is_list(Fake) andalso is_list(Real) ->
    {ok, Conf};
store({script_alias, Value}, _) ->
    {error, {wrong_type, {script_alias, Value}}}.

is_directory_index_list([]) ->
    true;
is_directory_index_list([Head | Tail]) when is_list(Head) ->
    is_directory_index_list(Tail);
is_directory_index_list(_) ->
    false.


%% ---------------------------------------------------------------------

which_alias(ConfigDB) ->
    httpd_util:multi_lookup(ConfigDB, alias). 

which_server_name(ConfigDB) ->
    httpd_util:lookup(ConfigDB, server_name).

which_port(ConfigDB) ->
    httpd_util:lookup(ConfigDB, port, 80). 

which_document_root(ConfigDB) ->
    httpd_util:lookup(ConfigDB, document_root, "").

which_directory_index(ConfigDB) ->
    httpd_util:lookup(ConfigDB, directory_index, []).

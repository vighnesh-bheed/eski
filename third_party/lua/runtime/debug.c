#include "internal.h"
#include "lstate.h"
#include <ctype.h>
#include <stdarg.h>

struct es_debug_state {
    es_buffer logs;
    size_t log_count, maxlen;
    uint64_t resumed_ns, eval_started_ns;
    int eval_timed_out;
    int line, stepping, dynamic, inspecting, detached, force_trace, hinted, protocol_error;
    int *breaks;
    size_t break_count, break_capacity;
};
typedef struct es_debug_state es_debug_state;

static uint64_t es_dclock(void) {
    struct timespec now;
    if(clock_gettime(CLOCK_MONOTONIC,&now))return 0;
    return (uint64_t)now.tv_sec*UINT64_C(1000000000)+(uint64_t)now.tv_nsec;
}

static void *es_dalloc(lua_State *L, void *ptr, size_t size) {
    es_context *ctx = es_context_of(L);
    void *out = es_allocate(ctx, ptr, size);
    if (!out && size) es_fail(L, ESLUA_MEMORY, "debugger memory limit exceeded");
    es_transient(ctx, out);
    return out;
}

static void es_dmark(es_buffer *buffer, es_context *ctx) {
    es_transient(ctx, buffer->data);
}

static void es_dlog(lua_State *L, const char *text, size_t len) {
    es_context *ctx = es_context_of(L);
    es_debug_state *state = ctx->debug;
    if (!state || state->detached) return;
    es_byte(L, &state->logs, '+');
    for (size_t i=0; i<len; i++) es_byte(L, &state->logs, text[i]=='\r' || text[i]=='\n' ? ' ' : (unsigned char)text[i]);
    es_append(L, &state->logs, "\r\n", 2);
    es_dmark(&state->logs, ctx); state->log_count++;
}

static void es_dfmt(lua_State *L, const char *format, ...) {
    char text[1024]; va_list args; va_start(args,format);
    int len=vsnprintf(text,sizeof(text),format,args); va_end(args);
    if (len<0) return;
    size_t count=(size_t)len; if(count>=sizeof(text)) count=sizeof(text)-1;
    es_dlog(L,text,count);
}

static int es_dflush(lua_State *L) {
    es_context *ctx=es_context_of(L); es_debug_state *state=ctx->debug;
    if(!state || state->detached || !state->log_count) return state && !state->detached;
    es_buffer frame={0}; char prefix[64]; int len=snprintf(prefix,sizeof(prefix),"*%zu\r\n",state->log_count);
    es_append(L,&frame,prefix,(size_t)len); es_append(L,&frame,state->logs.data,state->logs.len); es_dmark(&frame,ctx);
    int sent=ctx->callbacks.debug_write && ctx->callbacks.debug_write(ctx->callbacks.opaque,(eslua_arg){frame.data,frame.len});
    es_release(ctx,frame.data); state->logs.len=0; state->log_count=0;
    if(!sent) state->detached=1;
    return sent;
}

static int es_dbreak(es_debug_state *state,int line) {
    for(size_t i=0;i<state->break_count;i++) if(state->breaks[i]==line) return 1;
    return 0;
}

static int es_dsource(lua_State *L,int line, const unsigned char **text,size_t *len) {
    es_context *ctx=es_context_of(L); size_t begin=0; int number=1;
    while(number<line && begin<ctx->source.len) if(ctx->source.data[begin++]=='\n') number++;
    if(number!=line || begin>=ctx->source.len) return 0;
    size_t end=begin; while(end<ctx->source.len && ctx->source.data[end]!='\n') end++;
    if(end>begin && ctx->source.data[end-1]=='\r') end--;
    *text=ctx->source.data+begin; *len=end-begin; return 1;
}

static void es_dline(lua_State *L,int line) {
    es_debug_state *state=es_context_of(L)->debug; const unsigned char *text; size_t len;
    if(!es_dsource(L,line,&text,&len)) return;
    es_buffer out={0}; char prefix[64];
    int n=snprintf(prefix,sizeof(prefix),"%s%s%-3d ",line==state->line?"->":"  ",es_dbreak(state,line)?"#":" ",line);
    es_append(L,&out,prefix,(size_t)n); es_append(L,&out,text,len); es_dmark(&out,es_context_of(L));
    es_dlog(L,(const char *)out.data,out.len); es_release(es_context_of(L),out.data);
}

static void es_dlist(lua_State *L,int line,int context) {
    es_debug_state *state=es_context_of(L)->debug;
    if(line<=0) line=state->line;
    if(context<0) context=0;
    int begin=line>context?line-context:1;
    int64_t finish=(int64_t)line+context;
    if(finish>INT_MAX) finish=INT_MAX;
    for(int number=begin;number<=finish;number++) {
        const unsigned char *text; size_t len;
        if(!es_dsource(L,number,&text,&len)) break;
        es_dline(L,number);
        if(number==INT_MAX) break;
    }
}

static void es_dput(lua_State *L,es_buffer *out,const char *text,size_t len) {
    es_debug_state *state=es_context_of(L)->debug;
    size_t cap=state->maxlen?state->maxlen+64:es_context_of(L)->options.output_limit;
    if(out->len>=cap) return;
    if(len>cap-out->len) len=cap-out->len;
    es_append(L,out,text,len); es_dmark(out,es_context_of(L));
}

static void es_ddump(lua_State *L,int index,es_buffer *out,unsigned depth,const void **path) {
    index=lua_absindex(L,index); int type=lua_type(L,index); char text[96];
    if(type==LUA_TNIL) {es_dput(L,out,"nil",3);return;}
    if(type==LUA_TBOOLEAN) {const char *b=lua_toboolean(L,index)?"true":"false";es_dput(L,out,b,strlen(b));return;}
    if(type==LUA_TNUMBER) {int n=snprintf(text,sizeof(text),"%.14g",lua_tonumber(L,index));if(n>0)es_dput(L,out,text,(size_t)n);return;}
    if(type==LUA_TSTRING) {
        size_t len; const unsigned char *s=(const unsigned char *)lua_tolstring(L,index,&len); es_dput(L,out,"\"",1);
        for(size_t i=0;i<len;i++) {
            if(es_context_of(L)->debug->maxlen && out->len>es_context_of(L)->debug->maxlen+32) break;
            if(s[i]=='"' || s[i]=='\\') {char b[2]={'\\',(char)s[i]};es_dput(L,out,b,2);}
            else if(s[i]=='\n')es_dput(L,out,"\\n",2);
            else if(s[i]=='\r')es_dput(L,out,"\\r",2);
            else if(s[i]=='\t')es_dput(L,out,"\\t",2);
            else if(s[i]=='\a')es_dput(L,out,"\\a",2);
            else if(s[i]=='\b')es_dput(L,out,"\\b",2);
            else if(s[i]<32 || s[i]>=127) {int n=snprintf(text,sizeof(text),"\\x%02x",s[i]);es_dput(L,out,text,(size_t)n);}
            else es_dput(L,out,(const char *)s+i,1);
        }
        es_dput(L,out,"\"",1);return;
    }
    if(type!=LUA_TTABLE) {const char *name=lua_typename(L,type);es_dput(L,out,name,strlen(name));return;}
    const void *identity=lua_topointer(L,index);
    for(unsigned i=0;i<depth;i++)if(path[i]==identity){es_dput(L,out,"{...}",5);return;}
    if(depth>=8 || !lua_checkstack(L,8)){es_dput(L,out,"{...}",5);return;}
    path[depth]=identity; es_dput(L,out,"{",1); size_t count=0;
    size_t length=lua_objlen(L,index);
    if(length) {
        for(size_t i=1;i<=length;i++) {
            if(count++)es_dput(L,out,"; ",2);
            lua_rawgeti(L,index,(int)i);es_ddump(L,-1,out,depth+1,path);lua_pop(L,1);
            if(es_context_of(L)->debug->maxlen && out->len>es_context_of(L)->debug->maxlen) break;
        }
    } else {
        lua_pushnil(L);
        while(lua_next(L,index)) {
            if(count++)es_dput(L,out,"; ",2);
            es_dput(L,out,"[",1);es_ddump(L,-2,out,depth+1,path);es_dput(L,out,"]=",2);es_ddump(L,-1,out,depth+1,path);lua_pop(L,1);
            if(es_context_of(L)->debug->maxlen && out->len>es_context_of(L)->debug->maxlen){lua_pop(L,1);break;}
        }
    }
    es_dput(L,out,"}",1);
}

static void es_dtrimmed(lua_State *L,es_buffer *out) {
    es_context *ctx=es_context_of(L); es_debug_state *state=ctx->debug; int trimmed=0;
    if(state->maxlen && out->len>state->maxlen) {out->len=state->maxlen;es_append(L,out," ...",4);es_dmark(out,ctx);trimmed=1;}
    es_dlog(L,(const char *)out->data,out->len);
    if(trimmed&&!state->hinted){state->hinted=1;es_dfmt(L,"<hint> The above reply was trimmed. Use 'maxlen 0' to disable trimming.");}
}

static void es_dvalue(lua_State *L,const char *prefix,int index) {
    es_context *ctx=es_context_of(L); es_buffer out={0}; const void *path[9]={0};
    es_dput(L,&out,prefix,strlen(prefix));es_ddump(L,index,&out,0,path);
    es_dtrimmed(L,&out);es_release(ctx,out.data);
}

static int es_dnumber(eslua_arg arg,int *value) {
    if(!arg.len || arg.len>32) return 0;
    size_t i=0;int negative=arg.data[0]=='-';if(negative)i++;
    int64_t n=0;if(i==arg.len)return 0;
    if(arg.data[i]=='0'&&(negative||arg.len>1))return 0;
    for(;i<arg.len;i++){if(arg.data[i]<'0'||arg.data[i]>'9')return 0;n=n*10+arg.data[i]-'0';if(n>INT_MAX)return 0;}
    *value=negative?-(int)n:(int)n;return 1;
}

static int es_datoi(eslua_arg arg) {
    char text[64]; size_t len=arg.len<sizeof(text)-1?arg.len:sizeof(text)-1;
    memcpy(text,arg.data,len);text[len]=0;
    return (int)strtol(text,NULL,10);
}

static int es_dequal(eslua_arg arg,const char *text) {return arg.len==strlen(text)&&!memcmp(arg.data,text,arg.len);}

static eslua_arg *es_drequest(lua_State *L,eslua_result input,size_t *argc,void **owned,int *protocol) {
    *protocol=0;
    if(input.status || !input.data || !input.len) return NULL;
    unsigned char *copy=es_dalloc(L,NULL,input.len);memcpy(copy,input.data,input.len);*owned=copy;
    size_t pos=0;
    if(copy[pos++]!='*')return NULL;
    size_t count=0;
    while(pos<input.len && copy[pos]>='0'&&copy[pos]<='9'){if(count>1048576)return NULL;count=count*10+copy[pos++]-'0';}
    if(!count || count>1048576 || pos+2>input.len || copy[pos]!='\r'||copy[pos+1]!='\n')return NULL;
    if(count>1024){*protocol=1;return NULL;}
    pos+=2;eslua_arg *args=es_dalloc(L,NULL,count*sizeof(*args));
    for(size_t i=0;i<count;i++) {
        if(pos>=input.len||copy[pos++]!='$')return NULL;
        size_t len=0;
        while(pos<input.len && copy[pos]>='0'&&copy[pos]<='9'){if(len>input.len/10)return NULL;len=len*10+copy[pos++]-'0';}
        if(pos+2>input.len||copy[pos]!='\r'||copy[pos+1]!='\n')return NULL;pos+=2;
        if(len>input.len-pos||input.len-pos-len<2)return NULL;
        args[i]=(eslua_arg){copy+pos,len};pos+=len;
        if(copy[pos]!='\r'||copy[pos+1]!='\n')return NULL;pos+=2;
    }
    if(pos!=input.len)return NULL;*argc=count;return args;
}

static void es_dprint(lua_State *L,size_t argc,const eslua_arg *args) {
    int found=0; int top=lua_gettop(L);
    for(int level=0;level<128;level++) {
        lua_Debug frame;if(!lua_getstack(L,level,&frame))break;
        for(int local=1;;local++) {
            const char *name=lua_getlocal(L,&frame,local);if(!name)break;
            int match=name[0]!='(' && (argc==1 || (strlen(name)==args[1].len && !memcmp(name,args[1].data,args[1].len)));
            if(match){if(argc==1){char prefix[512];snprintf(prefix,sizeof(prefix),"<value> %s = ",name);es_dvalue(L,prefix,-1);}else es_dvalue(L,"<value> ",-1);found=1;}
            lua_pop(L,1);if(match&&argc>1)return;
        }
        if(argc>1) {
            lua_getinfo(L,"f",&frame);
            for(int up=1;;up++) {
                const char *name=lua_getupvalue(L,-1,up);if(!name)break;
                int match=strlen(name)==args[1].len&&!memcmp(name,args[1].data,args[1].len);
                if(match){es_dvalue(L,"<value> ",-1);lua_settop(L,top);return;}lua_pop(L,1);
            }
            lua_pop(L,1);
        }
        if(argc==1)break;
    }
    if(argc>1&&(es_dequal(args[1],"KEYS")||es_dequal(args[1],"ARGV"))) {
        lua_getglobal(L,es_dequal(args[1],"KEYS")?"KEYS":"ARGV");es_dvalue(L,"<value> ",-1);lua_pop(L,1);found=1;
    }
    if(!found)es_dfmt(L,argc==1?"No local variables in the current context.":"No such variable.");
}

static void es_deval(lua_State *L,size_t argc,const eslua_arg *args) {
    es_context *ctx=es_context_of(L);es_buffer code={0};
    es_append(L,&code,"return ",7);
    for(size_t i=1;i<argc;i++){if(i>1)es_byte(L,&code,' ');es_append(L,&code,args[i].data,args[i].len);}es_dmark(&code,ctx);
    int status=luaL_loadbuffer(L,(const char *)code.data,code.len,"@ldb_eval");
    if(status){lua_pop(L,1);status=luaL_loadbuffer(L,(const char *)code.data+7,code.len-7,"@ldb_eval");}
    if(!status){
        lu_byte allowhook=L->allowhook;
        ctx->debug->eval_started_ns=es_dclock();ctx->debug->eval_timed_out=0;
        L->allowhook=1;status=lua_pcall(L,0,1,0);L->allowhook=allowhook;
        ctx->debug->eval_started_ns=0;ctx->debug->eval_timed_out=0;
    }
    ctx->host_error_origin=0;
    if(status){size_t len;const char *text=lua_tolstring(L,-1,&len);es_buffer error={0};es_append(L,&error,"<error> ",8);if(text)es_append(L,&error,text,len);es_dmark(&error,ctx);es_dlog(L,(const char *)error.data,error.len);es_release(ctx,error.data);}
    else es_dvalue(L,"<retval> ",-1);
    lua_pop(L,1);es_release(ctx,code.data);
    if(ctx->sticky)es_fail(L,ctx->sticky,ctx->failure);
}

static void es_dtrace(lua_State *L) {
    int count=0;
    for(int level=0;level<128;level++){
        lua_Debug frame;if(!lua_getstack(L,level,&frame))break;lua_getinfo(L,"nSl",&frame);
        if(frame.what&&(!strcmp(frame.what,"C")||!strcmp(frame.what,"tail")))continue;
        const char *where=count?"From":"In";
        if(frame.name)es_dfmt(L,"%s %s:",where,frame.name);else es_dfmt(L,"%s top level:",where);
        es_dline(L,frame.currentline);count++;
    }
    if(!count)es_dfmt(L,"No Lua frames.");
}

static void es_dhelp(lua_State *L) {
    const char *lines[]={"Redis Lua debugger help:","[h]elp               Show this help.","[s]tep               Run current line and stop again.","[n]ext               Alias for step.","[c]ontinue           Run till next breakpoint.","[l]ist               List source code around current line.","[l]ist [line]        List source code around [line].","                     line = 0 means: current position.","[l]ist [line] [ctx]  In this form [ctx] specifies how many lines","                     to show before/after [line].","[w]hole              List all source code. Alias for 'list 1 1000000'.","[p]rint              Show all the local variables.","[p]rint <var>        Show the value of the specified variable.","                     Can also show global vars KEYS and ARGV.","[b]reak              Show all breakpoints.","[b]reak <line>       Add a breakpoint to the specified line.","[b]reak -<line>      Remove breakpoint from the specified line.","[b]reak 0            Remove all breakpoints.","[t]race              Show a backtrace.","[e]val <code>        Execute some Lua code (in a different callframe).","[r]edis <cmd>        Execute a Redis command.","[m]axlen [len]       Trim logged Redis replies and Lua var dumps to len.","                     Specifying zero as <len> means unlimited.","[a]bort              Stop the execution of the script. In sync","                     mode dataset changes will be retained.","","Debugger functions you can call from Lua scripts:","redis.debug()        Produce logs in the debugger console.","redis.breakpoint()   Stop execution like if there was a breakpoint in the","                     next line of code."};
    for(size_t i=0;i<sizeof(lines)/sizeof(*lines);i++)es_dfmt(L,"%s",lines[i]);
}

static int es_dequal_nocase(eslua_arg arg,const char *text) {
    size_t len=strlen(text);
    if(arg.len!=len)return 0;
    for(size_t i=0;i<len;i++)if(tolower(arg.data[i])!=text[i])return 0;
    return 1;
}

static void es_dloop(lua_State *L,const char *reason) {
    es_context *ctx=es_context_of(L);es_debug_state *state=ctx->debug;
    state->inspecting=1;
    es_dfmt(L,"* Stopped at %d, stop reason = %s",state->line,reason);es_dline(L,state->line);
    if(!es_dflush(L))goto disconnected;
    for(;;){
        eslua_result input=ctx->callbacks.debug_read?ctx->callbacks.debug_read(ctx->callbacks.opaque):(eslua_result){0};
        size_t argc=0;void *owned=NULL;int protocol=0;eslua_arg *args=es_drequest(L,input,&argc,&owned,&protocol);
        if(!args){
            es_release(ctx,owned);
            if(protocol){state->inspecting=0;state->protocol_error=1;ctx->sticky=ESLUA_KILLED;ctx->failure=NULL;lua_pushliteral(L,"protocol error");lua_error(L);}
            goto disconnected;
        }
        const char *names[]={"help","step","next","continue","abort","print","eval","trace","list","whole","maxlen","break","redis"};
        unsigned char command=0;
        if(args[0].len==1)command=(unsigned char)tolower(args[0].data[0]);
        else for(size_t i=0;i<sizeof(names)/sizeof(*names);i++)if(es_dequal_nocase(args[0],names[i]))command=(unsigned char)names[i][0];
        if(command=='r'&&argc<2)command=0;
        int resume=0;
        switch(command){
        case 's':case 'n':state->stepping=1;resume=1;break;
        case 'c':state->stepping=0;resume=1;break;
        case 'a':es_release(ctx,args);es_release(ctx,owned);state->inspecting=0;ctx->sticky=ESLUA_KILLED;ctx->failure=NULL;lua_pushliteral(L,"script aborted for user request");lua_error(L);break;
        case 'h':es_dhelp(L);break;
        case 'p':es_dprint(L,argc,args);break;
        case 'e':es_deval(L,argc,args);break;
        case 't':es_dtrace(L);break;
        case 'l':case 'w':{
            int line=state->line,context=5;
            if(command=='w'){line=1;context=INT_MAX-1;}
            else{if(argc>1)line=es_datoi(args[1]);if(argc>2)context=es_datoi(args[2]);}
            es_dlist(L,line,context);break;
        }
        case 'm':{
            if(argc>1){int len=es_datoi(args[1]);if(len!=0&&len<=60)len=60;state->maxlen=(size_t)len;state->hinted=1;}
            if(state->maxlen)es_dfmt(L,"<value> replies are truncated at %zu bytes.",state->maxlen);else es_dfmt(L,"<value> replies are unlimited.");break;
        }
        case 'b':{
            if(argc==1){
                if(!state->break_count)es_dfmt(L,"No breakpoints set. Use 'b <line>' to add one.");
                else{es_dfmt(L,"%zu breakpoints set:",state->break_count);for(size_t i=0;i<state->break_count;i++)es_dline(L,state->breaks[i]);}
            }
            else for(size_t i=1;i<argc;i++){
                int line;if(!es_dnumber(args[i],&line)){es_dfmt(L,"Invalid argument:'%.*s'",(int)(args[i].len>512?512:args[i].len),(const char *)args[i].data);continue;}
                if(!line){state->break_count=0;es_dfmt(L,"All breakpoints removed.");}
                else if(line<0){
                    int found=0;
                    for(size_t j=0;j<state->break_count;j++)if(state->breaks[j]==-line){memmove(state->breaks+j,state->breaks+j+1,(state->break_count-j-1)*sizeof(*state->breaks));state->break_count--;found=1;break;}
                    es_dfmt(L,found?"Breakpoint removed.":"No breakpoint in the specified line.");
                }
                else{
                    const unsigned char *text;size_t len;
                    if(es_dbreak(state,line)||!es_dsource(L,line,&text,&len)){es_dfmt(L,"Wrong line number.");continue;}
                    if(state->break_count==state->break_capacity){size_t cap=state->break_capacity?state->break_capacity*2:16;state->breaks=es_dalloc(L,state->breaks,cap*sizeof(*state->breaks));state->break_capacity=cap;}
                    state->breaks[state->break_count++]=line;
                    es_dlist(L,line,1);
                }
            }break;
        }
        case 'r':{
            if(argc>INT_MAX || !lua_checkstack(L,(int)argc+1)){es_dfmt(L,"<error> Too many Redis command arguments.");break;}
            int top=lua_gettop(L);state->force_trace=1;lua_pushcfunction(L,es_debug_call);
            for(size_t i=1;i<argc;i++)lua_pushlstring(L,(const char *)args[i].data,args[i].len);
            lua_pcall(L,(int)argc-1,1,0);ctx->host_error_origin=0;state->force_trace=0;lua_settop(L,top);
            if(ctx->sticky)es_fail(L,ctx->sticky,ctx->failure);break;
        }
        default:es_dfmt(L,"<error> Unknown Redis Lua debugger command or wrong number of arguments.");break;
        }
        es_release(ctx,args);es_release(ctx,owned);
        if(!resume&&!state->log_count)es_dfmt(L,"No source lines in range.");
        if(resume){state->inspecting=0;state->resumed_ns=es_dclock();return;}
        if(!es_dflush(L))goto disconnected;
    }
disconnected:
    state->detached=1;state->inspecting=0;state->stepping=0;
    if(ctx->options.debug_mode==1)es_fail(L,ESLUA_KILLED,"debugger disconnected");
}

int es_debug_active(lua_State *L) {
    es_debug_state *state=es_context_of(L)->debug;
    return state && !state->detached;
}

void es_debug_check(lua_State *L) {
    es_debug_state *state=es_context_of(L)->debug;
    if(state && state->inspecting && state->eval_timed_out)luaL_error(L,"debugger eval timed out");
}

void es_debug_begin(lua_State *L) {
    es_context *ctx=es_context_of(L);
    if(!ctx->options.debug_mode||ctx->debug||!ctx->callbacks.debug_read||!ctx->callbacks.debug_write)return;
    ctx->debug=es_dalloc(L,NULL,sizeof(*ctx->debug));memset(ctx->debug,0,sizeof(*ctx->debug));
    ctx->debug->maxlen=256;ctx->debug->stepping=1;ctx->debug->resumed_ns=es_dclock();
}

void es_debug_hook(lua_State *L,lua_Debug *debug) {
    es_context *ctx=es_context_of(L);es_debug_state *state=ctx->debug;
    if(!state||state->detached)return;
    L->ci->savedpc=L->savedpc;
    if(state->inspecting){
        if(ctx->options.instruction_limit && debug->event==LUA_HOOKCOUNT && state->eval_started_ns && (state->eval_timed_out || (es_dclock()-state->eval_started_ns)/1000000 >= (ctx->options.busy_threshold_ms?ctx->options.busy_threshold_ms:5000))){
            state->eval_timed_out=1;luaL_error(L,"debugger eval timed out");
        }
        return;
    }
    if(debug->event==LUA_HOOKLINE){
        lua_getinfo(L,"S",debug);
        if(!debug->source||strcmp(debug->source,"@user_script"))return;
        state->line=debug->currentline;
        const char *reason=state->dynamic?"redis.breakpoint() called":es_dbreak(state,state->line)?"break point":state->stepping?"step over":NULL;
        if(reason){state->dynamic=0;es_dloop(L,reason);}
    } else if(debug->event==LUA_HOOKCOUNT && (es_dclock()-state->resumed_ns)/1000000 >= (ctx->options.busy_threshold_ms?ctx->options.busy_threshold_ms:5000))es_dloop(L,"timeout reached, infinite loop?");
}

void es_debug_finish(lua_State *L) {
    es_debug_state *state=es_context_of(L)->debug;
    if(!state||state->detached)return;
    es_dfmt(L,"<endsession>");es_dflush(L);state->detached=1;
}

static int es_dtracing(es_debug_state *state) {
    return state->force_trace||(state->stepping&&!state->inspecting);
}

void es_debug_command(lua_State *L,int argc,const eslua_arg *args) {
    es_context *ctx=es_context_of(L);es_debug_state *state=ctx->debug;
    if(!state||state->detached||!es_dtracing(state))return;
    es_buffer out={0};es_append(L,&out,"<redis>",7);
    int shown=argc>10?10:argc;
    for(int i=0;i<shown;i++){es_byte(L,&out,' ');es_append(L,&out,args[i].data,args[i].len);}
    if(argc>10){char more[64];int n=snprintf(more,sizeof(more)," ... (%d more)",argc-11);if(n>0)es_append(L,&out,more,(size_t)n);}
    es_dmark(&out,ctx);
    es_dlog(L,(const char *)out.data,out.len);es_release(ctx,out.data);
}

static void es_drepr(lua_State *L,es_buffer *out,unsigned char tag,const unsigned char *s,size_t len) {
    char text[8];
    es_dput(L,out,"\"",1);
    if(tag)es_dput(L,out,(const char *)&tag,1);
    for(size_t i=0;i<len;i++) {
        es_debug_state *state=es_context_of(L)->debug;
        if(state->maxlen && out->len>state->maxlen+32) break;
        if(s[i]=='"' || s[i]=='\\') {char b[2]={'\\',(char)s[i]};es_dput(L,out,b,2);}
        else if(s[i]=='\n')es_dput(L,out,"\\n",2);
        else if(s[i]=='\r')es_dput(L,out,"\\r",2);
        else if(s[i]=='\t')es_dput(L,out,"\\t",2);
        else if(s[i]=='\a')es_dput(L,out,"\\a",2);
        else if(s[i]=='\b')es_dput(L,out,"\\b",2);
        else if(s[i]<32 || s[i]>=127) {int n=snprintf(text,sizeof(text),"\\x%02x",s[i]);es_dput(L,out,text,(size_t)n);}
        else es_dput(L,out,(const char *)s+i,1);
    }
    es_dput(L,out,"\"",1);
}

static int es_dresp_line(const unsigned char *data,size_t len,size_t *pos,const unsigned char **line,size_t *line_len) {
    size_t begin=*pos,end=begin;
    while(end+1<len && !(data[end]=='\r'&&data[end+1]=='\n'))end++;
    if(end+1>=len)return 0;
    *line=data+begin;*line_len=end-begin;*pos=end+2;return 1;
}

static int64_t es_dresp_count(const unsigned char *line,size_t len) {
    char text[32];if(!len||len>=sizeof(text))return -2;
    memcpy(text,line,len);text[len]=0;
    char *end;long long value=strtoll(text,&end,10);
    if(*end)return -2;
    return value;
}

static int es_dresp(lua_State *L,es_buffer *out,const unsigned char *data,size_t len,size_t *pos,unsigned depth) {
    if(*pos>=len||depth>64)return 0;
    unsigned char tag=data[(*pos)++];
    const unsigned char *line;size_t line_len;
    if(!es_dresp_line(data,len,pos,&line,&line_len))return 0;
    switch(tag){
    case '+':case '-':es_drepr(L,out,tag,line,line_len);return 1;
    case ':':es_dput(L,out,(const char *)line,line_len);return 1;
    case ',':es_dput(L,out,"(double) ",9);es_dput(L,out,(const char *)line,line_len);return 1;
    case '_':es_dput(L,out,"(null)",6);return 1;
    case '#':case '(':return 1;
    case '$':case '=':case '!':{
        int64_t n=es_dresp_count(line,line_len);
        if(n==-1&&tag=='$'){es_dput(L,out,"NULL",4);return 1;}
        if(n<0||(uint64_t)n>len-*pos||len-*pos-(size_t)n<2)return 0;
        if(tag=='$')es_drepr(L,out,0,data+*pos,(size_t)n);
        *pos+=(size_t)n+2;return 1;
    }
    case '*':case '~':case '%':case '>':case '|':{
        int64_t n=es_dresp_count(line,line_len);
        if(n==-1&&tag=='*'){es_dput(L,out,"NULL",4);return 1;}
        if(n<0||(uint64_t)n>len)return 0;
        if(tag=='|'){
            es_buffer skipped={0};
            for(int64_t i=0;i<n*2;i++){if(!es_dresp(L,&skipped,data,len,pos,depth+1)){es_release(es_context_of(L),skipped.data);return 0;}}
            es_release(es_context_of(L),skipped.data);
            return es_dresp(L,out,data,len,pos,depth+1);
        }
        const char *open=tag=='~'?"~(":tag=='%'?"{":"[",*close=tag=='~'?")":tag=='%'?"}":"]";
        es_dput(L,out,open,strlen(open));
        for(int64_t i=0;i<n;i++){
            if(i)es_dput(L,out,",",1);
            if(!es_dresp(L,out,data,len,pos,depth+1))return 0;
            if(tag=='%'){es_dput(L,out," => ",4);if(!es_dresp(L,out,data,len,pos,depth+1))return 0;}
        }
        es_dput(L,out,close,strlen(close));return 1;
    }
    }
    return 0;
}

void es_debug_reply(lua_State *L,const eslua_result *result) {
    es_context *ctx=es_context_of(L);es_debug_state *state=ctx->debug;
    if(!state||state->detached||!es_dtracing(state)||!result->data||!result->len)return;
    const unsigned char *data=result->data;size_t len=result->len;
    if(result->rejected||data[0]=='-'){
        size_t end=0;while(end+1<len&&!(data[end]=='\r'&&data[end+1]=='\n'))end++;
        const unsigned char *text=data;size_t text_len=end;
        if(result->rejected){
            if(text_len&&text[0]=='-'){text++;text_len--;}
            if(text_len>=4&&!memcmp(text,"ERR ",4)){text+=4;text_len-=4;}
        }
        es_buffer error={0};es_append(L,&error,"<error> ",8);es_append(L,&error,text,text_len);es_dmark(&error,ctx);
        es_dlog(L,(const char *)error.data,error.len);es_release(ctx,error.data);
        if(result->rejected)return;
    }
    es_buffer out={0};es_dput(L,&out,"<reply> ",8);
    size_t pos=0;size_t mark=out.len;
    if(!es_dresp(L,&out,data,len,&pos,0))out.len=mark;
    es_dtrimmed(L,&out);es_release(ctx,out.data);
}

int es_debug_log(lua_State *L) {
    es_context *ctx=es_context_of(L);es_debug_state *state=ctx->debug;
    if(!state||state->detached)return 0;
    es_buffer out={0};char prefix[96];int n=snprintf(prefix,sizeof(prefix),"<debug> line %d: ",state->line);es_append(L,&out,prefix,(size_t)n);es_dmark(&out,ctx);
    const void *path[9]={0};int argc=lua_gettop(L);
    for(int i=1;i<=argc;i++){if(i>1)es_dput(L,&out,", ",2);es_ddump(L,i,&out,0,path);}
    es_dlog(L,(const char *)out.data,out.len);es_release(ctx,out.data);return 0;
}

int es_debug_breakpoint(lua_State *L) {
    es_debug_state *state=es_context_of(L)->debug;
    if(state&&!state->detached)state->dynamic=1;
    lua_pushboolean(L,state&&!state->detached);return 1;
}

const testing = (props) => {
    const { children } = props;

    return (
        <TEST>
            <Hello />
            {children}
        </TEST>
    );
}